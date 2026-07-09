import AppKit
import CMUXMobileCore
import CmuxTerminal
import Foundation
import GhosttyKit

@MainActor
final class TerminalInlineImageController {
    private nonisolated static let sharedThumbnailCache = TerminalInlineImageThumbnailCache()
    private nonisolated static let surfaceOutputDemand = RenderDemandCounter()
    private nonisolated static let surfaceOutputLock = NSLock()
    // SAFETY: guarded by `surfaceOutputLock`; written from the PTY tee thread and drained on main.
    nonisolated(unsafe) private static var pendingOutputSurfaceIDs: Set<UUID> = []
    // SAFETY: guarded by `surfaceOutputLock`; coalesces one main-actor notification drain.
    nonisolated(unsafe) private static var surfaceOutputFlushScheduled = false
    private nonisolated static let thumbnailRetryDelay: TimeInterval = 5
    private nonisolated static let maximumThumbnailRetryEntries = 384

    private weak var hostedView: GhosttySurfaceScrollView?
    private weak var overlayView: TerminalInlineImageOverlayView?
    private let scanner = TerminalTranscriptImagePathScanner()
    private let reconciler = TerminalInlineImageReconciler()
    private let cache: TerminalInlineImageThumbnailCache
    private let scanQueue = DispatchQueue(label: "com.cmux.inline-image-scan", qos: .utility)
    private var settingsObserver: TerminalInlineImageSettingsObserver?
    private var observers: [NSObjectProtocol] = []
    private var releaseFrameDemand: (() -> Void)?
    private var releaseSurfaceOutputDemand: (() -> Void)?
    private var surfaceOutputObserver: NSObjectProtocol?
    private var observedOutputSurfaceID: UUID?
    private var debounceTimer: DispatchSourceTimer?
    private var pendingScanFirstRequestedAt: DispatchTime?
    private var scanGeneration: UInt64 = 0
    private var lastScannedGridJSON: Data?
    private var lastScannedRowOffset: Int?
    private var annotations: [TerminalInlineImageAnnotation] = []
    private var thumbnailsByID: [UUID: TerminalInlineImageThumbnail] = [:]
    private var pendingThumbnailPaths: Set<String> = []
    private var thumbnailRetryAfterByPath: [String: Date] = [:]
    private var thumbnailRetryPathOrder: [String] = []
    private var isEnabled = false

    init(
        hostedView: GhosttySurfaceScrollView,
        overlayView: TerminalInlineImageOverlayView,
        cache: TerminalInlineImageThumbnailCache = TerminalInlineImageController.sharedThumbnailCache
    ) {
        self.hostedView = hostedView
        self.overlayView = overlayView
        self.cache = cache
        settingsObserver = TerminalInlineImageSettingsObserver { [weak self] enabled in
            self?.setEnabled(enabled)
        }
    }

    func start() {
        settingsObserver?.start()
        setEnabled(TerminalInlineImageSettings.isEnabled())
    }

    func stop() {
        settingsObserver?.stop()
        setEnabled(false)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surfaceOutputObserver {
            NotificationCenter.default.removeObserver(surfaceOutputObserver)
        }
        releaseFrameDemand?()
        releaseSurfaceOutputDemand?()
        debounceTimer?.cancel()
    }

    nonisolated static func noteSurfaceOutput(surfaceID: UUID) {
        guard surfaceOutputDemand.isActive else { return }
        surfaceOutputLock.lock()
        pendingOutputSurfaceIDs.insert(surfaceID)
        let shouldSchedule = !surfaceOutputFlushScheduled
        surfaceOutputFlushScheduled = true
        surfaceOutputLock.unlock()
        guard shouldSchedule else { return }
        Task { @MainActor in
            flushSurfaceOutputNotifications()
        }
    }

    nonisolated private static func retainSurfaceOutputNotifications() -> () -> Void {
        let retention = surfaceOutputDemand.retain()
        return { retention.release() }
    }

    nonisolated private static func surfaceOutputNotificationName(for surfaceID: UUID) -> Notification.Name {
        Notification.Name("cmux.terminalInlineImage.surfaceOutput.\(surfaceID.uuidString)")
    }

    @MainActor
    private static func flushSurfaceOutputNotifications() {
        surfaceOutputLock.lock()
        let surfaceIDs = pendingOutputSurfaceIDs
        pendingOutputSurfaceIDs.removeAll()
        surfaceOutputFlushScheduled = false
        surfaceOutputLock.unlock()
        for surfaceID in surfaceIDs {
            NotificationCenter.default.post(
                name: surfaceOutputNotificationName(for: surfaceID),
                object: nil
            )
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            startSurfaceObservers()
            scheduleScan()
        } else {
            stopSurfaceObservers()
            cancelDebounce()
            lastScannedGridJSON = nil
            lastScannedRowOffset = nil
            clearAnnotations()
            if !TerminalInlineImageSettings.isEnabled() {
                cache.removeAll()
            }
        }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        installSurfaceOutputObserver(for: terminalSurface.id)
        scheduleScanForVisibleViewport()
    }

    private func startSurfaceObservers() {
        guard observers.isEmpty, let hostedView else { return }
        releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
        releaseSurfaceOutputDemand = Self.retainSurfaceOutputNotifications()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        })
        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        })
        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        })
        if let surfaceID = hostedView.surfaceView.terminalSurface?.id {
            installSurfaceOutputObserver(for: surfaceID)
        }
        // Ticks are skipped while the window is occluded, so catch up when it
        // becomes visible again instead of waiting for the next PTY output.
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = self.hostedView?.window,
                      (note.object as? NSWindow) === window else {
                    return
                }
                self.scheduleScanForVisibleViewport()
            }
        })
    }

    private func scheduleScanForVisibleViewport() {
        guard let hostedView,
              let window = hostedView.window,
              !hostedView.isHiddenOrHasHiddenAncestor,
              !hostedView.surfaceView.isHiddenOrHasHiddenAncestor,
              hostedView.bounds.width > 1,
              hostedView.bounds.height > 1,
              window.occlusionState.contains(.visible) else {
            return
        }
        scheduleScan()
    }

    private func stopSurfaceObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let surfaceOutputObserver {
            NotificationCenter.default.removeObserver(surfaceOutputObserver)
        }
        surfaceOutputObserver = nil
        observedOutputSurfaceID = nil
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseSurfaceOutputDemand?()
        releaseSurfaceOutputDemand = nil
    }

    private func installSurfaceOutputObserver(for surfaceID: UUID) {
        guard isEnabled else { return }
        guard observedOutputSurfaceID != surfaceID || surfaceOutputObserver == nil else { return }
        if let surfaceOutputObserver {
            NotificationCenter.default.removeObserver(surfaceOutputObserver)
        }
        observedOutputSurfaceID = surfaceID
        surfaceOutputObserver = NotificationCenter.default.addObserver(
            forName: Self.surfaceOutputNotificationName(for: surfaceID),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScanForVisibleViewport() }
        }
    }

    private func scheduleScan() {
        guard isEnabled else { return }
        let now = DispatchTime.now()
        if pendingScanFirstRequestedAt == nil {
            pendingScanFirstRequestedAt = now
        }
        let timer = debounceTimer ?? makeDebounceTimer()
        let deadline: DispatchTime
        if let firstRequestedAt = pendingScanFirstRequestedAt,
           now.uptimeNanoseconds - firstRequestedAt.uptimeNanoseconds >= 600_000_000 {
            deadline = .now()
        } else {
            deadline = .now() + .milliseconds(200)
        }
        timer.schedule(deadline: deadline, leeway: .milliseconds(40))
    }

    private func makeDebounceTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.pendingScanFirstRequestedAt = nil
                self?.rescan()
            }
        }
        debounceTimer = timer
        timer.resume()
        return timer
    }

    private func cancelDebounce() {
        debounceTimer?.cancel()
        debounceTimer = nil
        pendingScanFirstRequestedAt = nil
    }

    private func rescan() {
        guard isEnabled,
              let hostedView,
              let terminalSurface = hostedView.surfaceView.terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(terminalSurface.id),
              let gridJSON = terminalSurface.mobileRenderGridJSON(stateSeq: 0) else {
            lastScannedGridJSON = nil
            lastScannedRowOffset = nil
            clearAnnotations()
            return
        }
        let rowOffset = Int(clamping: hostedView.surfaceView.scrollbar?.offset ?? 0)
        if gridJSON == lastScannedGridJSON, rowOffset == lastScannedRowOffset {
            // The visible grid did not change, so skip the decode + scan. Still
            // re-render from current metrics (cell size can change without
            // changing grid bytes) and retry thumbnails that are still missing
            // (e.g. the file appeared on disk after its path was printed).
            render()
            requestMissingThumbnails(for: annotations)
            return
        }
        scanGeneration &+= 1
        let generation = scanGeneration
        let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
        let context = TerminalTranscriptImagePathScanner.Context(
            cwd: cwd,
            homeDirectory: NSHomeDirectory()
        )
        let scanner = scanner
        scanQueue.async { [weak self] in
            var detected: [DetectedImagePath]?
            if let frame = try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: gridJSON),
               frame.activeScreen == .primary {
                detected = scanner.scan(rows: frame.plainRows(), context: context)
            }
            let scanned = detected
            Task { @MainActor in
                self?.applyScanResult(scanned, gridJSON: gridJSON, rowOffset: rowOffset, generation: generation)
            }
        }
    }

    private func applyScanResult(
        _ detected: [DetectedImagePath]?,
        gridJSON: Data,
        rowOffset: Int,
        generation: UInt64
    ) {
        guard isEnabled, generation == scanGeneration else { return }
        lastScannedGridJSON = gridJSON
        lastScannedRowOffset = rowOffset
        guard let detected else {
            clearAnnotations()
            return
        }
        let nextAnnotations = reconciler.reconcile(
            existing: annotations,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: rowOffset)
        )
        annotations = nextAnnotations
        let liveIDs = Set(nextAnnotations.map(\.id))
        let livePaths = Set(nextAnnotations.map(\.resolvedPath))
        thumbnailsByID = thumbnailsByID.filter { liveIDs.contains($0.key) }
        thumbnailRetryAfterByPath = thumbnailRetryAfterByPath.filter { livePaths.contains($0.key) }
        thumbnailRetryPathOrder = thumbnailRetryPathOrder.filter { thumbnailRetryAfterByPath[$0] != nil }
        render()
        requestMissingThumbnails(for: nextAnnotations)
    }

    private func requestMissingThumbnails(for annotations: [TerminalInlineImageAnnotation]) {
        let now = Date()
        for annotation in annotations
        where thumbnailsByID[annotation.id] == nil {
            let path = annotation.resolvedPath
            guard !pendingThumbnailPaths.contains(path) else { continue }
            if let retryAfter = thumbnailRetryAfterByPath[path] {
                guard retryAfter <= now else { continue }
                thumbnailRetryAfterByPath.removeValue(forKey: path)
            }
            pendingThumbnailPaths.insert(path)
            cache.thumbnail(for: path) { [weak self, path] thumbnail in
                Task { @MainActor in
                    self?.receiveThumbnail(thumbnail, path: path)
                }
            }
        }
    }

    private func receiveThumbnail(
        _ thumbnail: TerminalInlineImageThumbnail?,
        path: String
    ) {
        pendingThumbnailPaths.remove(path)
        let matchingAnnotations = annotations.filter { $0.resolvedPath == path }
        guard !matchingAnnotations.isEmpty else { return }
        guard let thumbnail else {
            rememberThumbnailFailure(for: path)
            return
        }
        thumbnailRetryAfterByPath.removeValue(forKey: path)
        for annotation in matchingAnnotations {
            thumbnailsByID[annotation.id] = thumbnail
        }
        render()
    }

    private func rememberThumbnailFailure(for path: String) {
        if thumbnailRetryAfterByPath[path] == nil {
            thumbnailRetryPathOrder.append(path)
        }
        thumbnailRetryAfterByPath[path] = Date().addingTimeInterval(Self.thumbnailRetryDelay)
        guard thumbnailRetryPathOrder.count > Self.maximumThumbnailRetryEntries else { return }
        let overflow = thumbnailRetryPathOrder.count - Self.maximumThumbnailRetryEntries
        for expiredPath in thumbnailRetryPathOrder.prefix(overflow) {
            thumbnailRetryAfterByPath.removeValue(forKey: expiredPath)
        }
        thumbnailRetryPathOrder.removeFirst(overflow)
    }

    private func render() {
        guard let hostedView,
              let overlayView,
              let surface = hostedView.surfaceView.terminalSurface?.surface else {
            overlayView?.clear()
            return
        }
        let surfaceView = hostedView.surfaceView
        // `surfaceView.cellSize` (and the copy-mode grid metrics built from
        // it) carries Ghostty's raw pixel cell size, so derive the point-space
        // grid from the surface size and backing scale, the same way
        // TerminalSurface.mobileScroll does.
        let size = ghostty_surface_size(surface)
        let scale = max(surfaceView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        guard cellWidth > 0, cellHeight > 0 else {
            overlayView.clear()
            return
        }
        let xInset = max(0, (surfaceView.bounds.width - CGFloat(size.columns) * cellWidth) / 2)
        let yInset = max(0, (surfaceView.bounds.height - CGFloat(size.rows) * cellHeight) / 2)
        let items = annotations.compactMap { annotation -> TerminalInlineImageOverlayItem? in
            guard let thumbnail = thumbnailsByID[annotation.id] else { return nil }
            let rowTopFromTop = yInset + CGFloat(annotation.rowIndex) * cellHeight
            let cellRect = CGRect(
                x: xInset,
                y: surfaceView.bounds.height - rowTopFromTop - cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            return TerminalInlineImageOverlayItem(
                annotation: annotation,
                thumbnail: thumbnail,
                anchorRect: overlayView.convert(cellRect, from: surfaceView)
            )
        }
        overlayView.update(items: items)
    }

    private func clearAnnotations() {
        annotations.removeAll()
        thumbnailsByID.removeAll()
        pendingThumbnailPaths.removeAll()
        thumbnailRetryAfterByPath.removeAll()
        thumbnailRetryPathOrder.removeAll()
        overlayView?.clear()
    }
}
