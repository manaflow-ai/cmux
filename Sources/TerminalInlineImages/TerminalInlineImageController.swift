import AppKit
import CMUXMobileCore
import CmuxTerminal
import Foundation

@MainActor
final class TerminalInlineImageController {
    private weak var hostedView: GhosttySurfaceScrollView?
    private weak var overlayView: TerminalInlineImageOverlayView?
    private let scanner = TerminalTranscriptImagePathScanner()
    private let reconciler = TerminalInlineImageReconciler()
    private let cache = TerminalInlineImageThumbnailCache()
    private let scanQueue = DispatchQueue(label: "com.cmux.inline-image-scan", qos: .utility)
    private var settingsObserver: TerminalInlineImageSettingsObserver?
    private var observers: [NSObjectProtocol] = []
    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var debounceTimer: DispatchSourceTimer?
    private var pendingScanFirstRequestedAt: DispatchTime?
    private var scanGeneration: UInt64 = 0
    private var lastScannedGridJSON: Data?
    private var lastScannedRowOffset: Int?
    private var annotations: [TerminalInlineImageAnnotation] = []
    private var thumbnailsByID: [UUID: TerminalInlineImageThumbnail] = [:]
    private var pendingThumbnailIDs: Set<UUID> = []
    private var isEnabled = false

    init(hostedView: GhosttySurfaceScrollView, overlayView: TerminalInlineImageOverlayView) {
        self.hostedView = hostedView
        self.overlayView = overlayView
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
        releaseFrameDemand?()
        releaseTickDemand?()
        debounceTimer?.cancel()
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
        }
    }

    private func startSurfaceObservers() {
        guard observers.isEmpty, let hostedView else { return }
        releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
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
        // Render-frame notifications only post when Ghostty's Metal layer
        // vends a drawable, which it skips in common configurations, and
        // scrollbar updates only fire when scrollback geometry changes —
        // neither covers plain output at a fresh prompt. Ticks fire on every
        // Ghostty IO cycle (see MobileTerminalRenderObserver), so they are
        // the reliable output signal. The occlusion gate below plus the
        // debounce and the byte-identical grid dedupe keep the per-tick cost
        // to at most one coalesced export + compare per debounce window, and
        // only for surfaces the user can actually see.
        releaseTickDemand = GhosttyApp.retainTickNotifications()
        observers.append(center.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScanForVisibleViewport() }
        })
    }

    private func scheduleScanForVisibleViewport() {
        guard let window = hostedView?.window,
              window.occlusionState.contains(.visible) else {
            return
        }
        scheduleScan()
    }

    private func stopSurfaceObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseTickDemand?()
        releaseTickDemand = nil
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
        let context = TerminalTranscriptImagePathScanner.Context(
            cwd: terminalSurface.requestedWorkingDirectory,
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
        thumbnailsByID = thumbnailsByID.filter { liveIDs.contains($0.key) }
        pendingThumbnailIDs.formIntersection(liveIDs)
        render()
        requestMissingThumbnails(for: nextAnnotations)
    }

    private func requestMissingThumbnails(for annotations: [TerminalInlineImageAnnotation]) {
        for annotation in annotations
        where thumbnailsByID[annotation.id] == nil && !pendingThumbnailIDs.contains(annotation.id) {
            pendingThumbnailIDs.insert(annotation.id)
            cache.thumbnail(for: annotation.resolvedPath) { [weak self, id = annotation.id, key = annotation.key] thumbnail in
                Task { @MainActor in
                    self?.receiveThumbnail(thumbnail, id: id, key: key)
                }
            }
        }
    }

    private func receiveThumbnail(
        _ thumbnail: TerminalInlineImageThumbnail?,
        id: UUID,
        key: TerminalInlineImageAnnotationKey
    ) {
        pendingThumbnailIDs.remove(id)
        guard let thumbnail,
              annotations.contains(where: { $0.id == id && $0.key == key }) else {
            return
        }
        thumbnailsByID[id] = thumbnail
        render()
    }

    private func render() {
        guard let hostedView,
              let overlayView,
              let surface = hostedView.surfaceView.terminalSurface?.surface else {
            overlayView?.clear()
            return
        }
        let items = annotations.compactMap { annotation -> TerminalInlineImageOverlayItem? in
            guard let thumbnail = thumbnailsByID[annotation.id] else { return nil }
            return TerminalInlineImageOverlayItem(annotation: annotation, thumbnail: thumbnail)
        }
        overlayView.update(
            items: items,
            metrics: hostedView.surfaceView.keyboardCopyModeGridMetrics(surface: surface)
        )
    }

    private func clearAnnotations() {
        annotations.removeAll()
        thumbnailsByID.removeAll()
        pendingThumbnailIDs.removeAll()
        overlayView?.clear()
    }
}
