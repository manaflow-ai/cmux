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
    private var settingsObserver: TerminalInlineImageSettingsObserver?
    private var observers: [NSObjectProtocol] = []
    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var debounceTimer: DispatchSourceTimer?
    private var annotations: [TerminalInlineImageAnnotation] = []
    private var thumbnailsByID: [UUID: TerminalInlineImageThumbnail] = [:]
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
        stopSurfaceObservers()
        cancelDebounce()
        clearAnnotations()
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
            clearAnnotations()
        }
    }

    private func startSurfaceObservers() {
        guard observers.isEmpty, let hostedView else { return }
        releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
        releaseTickDemand = GhosttyApp.retainTickNotifications()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan() }
        })
        observers.append(center.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
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
        let timer = debounceTimer ?? makeDebounceTimer()
        timer.schedule(deadline: .now() + .milliseconds(200), leeway: .milliseconds(40))
    }

    private func makeDebounceTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
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
    }

    private func rescan() {
        guard isEnabled,
              let hostedView,
              let terminalSurface = hostedView.surfaceView.terminalSurface,
              let snapshot = terminalSurface.mobileRenderGridFrame(stateSeq: 0, full: true, scrollbackLines: 0),
              snapshot.frame.activeScreen == .primary else {
            clearAnnotations()
            return
        }
        let context = TerminalTranscriptImagePathScanner.Context(
            cwd: terminalSurface.requestedWorkingDirectory,
            homeDirectory: NSHomeDirectory()
        )
        let detected = scanner.scan(rows: snapshot.rows, context: context)
        let rowOffset = Int(clamping: hostedView.surfaceView.scrollbar?.offset ?? 0)
        let nextAnnotations = reconciler.reconcile(
            existing: annotations,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: rowOffset)
        )
        annotations = nextAnnotations
        let liveIDs = Set(nextAnnotations.map(\.id))
        thumbnailsByID = thumbnailsByID.filter { liveIDs.contains($0.key) }
        render()
        requestMissingThumbnails(for: nextAnnotations)
    }

    private func requestMissingThumbnails(for annotations: [TerminalInlineImageAnnotation]) {
        for annotation in annotations where thumbnailsByID[annotation.id] == nil {
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
        overlayView?.clear()
    }
}
