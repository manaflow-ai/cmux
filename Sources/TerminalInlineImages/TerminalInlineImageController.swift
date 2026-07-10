import AppKit
import CmuxTerminal
import Foundation

@MainActor
final class TerminalInlineImageController: TerminalInlineImageScanCoordinatorDelegate {
    private nonisolated static let thumbnailRetryDelay: Duration = .seconds(5)
    private nonisolated static let maximumThumbnailRetryDelay: Duration = .seconds(30)
    private nonisolated static let maximumThumbnailRetryAttempts = 5
    private weak var hostedView: GhosttySurfaceScrollView?
    private weak var overlayView: TerminalInlineImageOverlayView?
    private let reconciler = TerminalInlineImageReconciler()
    private let renderer = TerminalInlineImageRenderer()
    private let cache: TerminalInlineImageThumbnailCache
    private let outputService: TerminalInlineImageOutputService
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private var scanCoordinator: TerminalInlineImageScanCoordinator!
    private var settingsObserver: TerminalInlineImageSettingsObserver?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var eventSubscription: TerminalInlineImageEventSubscription?
    private var renderedFrameGate = TerminalInlineImageRenderedFrameGate()
    private var activeSession: TerminalInlineImageSession?
    private var lastScannedGridJSON: Data?
    private var lastScannedRowOffset: Int?
    private var annotations: [TerminalInlineImageAnnotation] = []
    private var thumbnailsByID: [UUID: TerminalInlineImageThumbnail] = [:]
    private var thumbnailLoadTasksByPath: [String: Task<Void, Never>] = [:]
    private var thumbnailLoadIDsByPath: [String: UUID] = [:]
    private var thumbnailRetryAttemptByPath: [String: Int] = [:]
    private var thumbnailRetryTasksByPath: [String: Task<Void, Never>] = [:]
    private var isEnabled = false
    private var isVisibleInUI = true

    init(
        hostedView: GhosttySurfaceScrollView,
        overlayView: TerminalInlineImageOverlayView,
        scannerService: TerminalInlineImageScannerService = TerminalInlineImageScannerService(),
        cache: TerminalInlineImageThumbnailCache = GhosttyApp.terminalInlineImageThumbnailCache,
        outputService: TerminalInlineImageOutputService = GhosttyApp.terminalInlineImageOutputService,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        },
        scanPacingSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.hostedView = hostedView
        self.overlayView = overlayView
        self.cache = cache
        self.outputService = outputService
        self.retrySleep = retrySleep
        scanCoordinator = TerminalInlineImageScanCoordinator(
            delegate: self,
            scannerService: scannerService,
            pacingSleep: scanPacingSleep
        )
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
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        thumbnailLoadTasksByPath.values.forEach { $0.cancel() }
        thumbnailRetryTasksByPath.values.forEach { $0.cancel() }
    }

    func setVisibleInUI(_ visible: Bool) {
        guard isVisibleInUI != visible else { return }
        isVisibleInUI = visible
        if visible {
            startLifecycleObservers()
            refreshActiveSession()
            requestScanForActiveSession()
        } else {
            endActiveSession()
            stopLifecycleObservers()
        }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        if let activeSession, activeSession.surfaceID != terminalSurface.id {
            endActiveSession()
        }
        refreshActiveSession()
        requestScanForActiveSession()
    }

    func hostedViewDidMoveToWindow() {
        guard isEnabled, isVisibleInUI else {
            endActiveSession()
            return
        }
        startLifecycleObservers()
        refreshActiveSession()
        requestScanForActiveSession()
    }

    func hostedViewDidUnhide() {
        guard isEnabled, isVisibleInUI else { return }
        startLifecycleObservers()
        refreshActiveSession()
        requestScanForActiveSession()
    }

    func notePotentialLocalGridMutation() {
        guard activeSession != nil else { return }
        renderedFrameGate.noteGridMutation()
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            startLifecycleObservers()
            refreshActiveSession()
            requestScanForActiveSession()
        } else {
            endActiveSession()
            stopLifecycleObservers()
            if !TerminalInlineImageSettings.isEnabled() {
                let cache = cache
                Task {
                    await cache.removeAll()
                }
            }
        }
    }

    private func startLifecycleObservers() {
        guard isEnabled, isVisibleInUI, lifecycleObservers.isEmpty, let hostedView else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestScanForActiveSession(paced: true)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestScanForActiveSession()
            }
        })
        lifecycleObservers.append(center.addObserver(
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
                self.refreshActiveSession()
                self.requestScanForActiveSession()
            }
        })
    }

    private func stopLifecycleObservers() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    private func refreshActiveSession() {
        guard let hostedView,
              let (terminalSurface, workspace) = activeSessionCandidate() else {
            endActiveSession()
            return
        }
        if activeSession?.matches(surfaceID: terminalSurface.id, workspace: workspace) == true {
            return
        }
        endActiveSession()
        activeSession = TerminalInlineImageSession(
            surfaceID: terminalSurface.id,
            workspace: workspace
        )
        eventSubscription = TerminalInlineImageEventSubscription(
            surfaceView: hostedView.surfaceView,
            terminalSurface: terminalSurface,
            outputService: outputService,
            onRenderedFrame: { [weak self] in
                guard let self, self.renderedFrameGate.consumeRenderedFrame() else { return }
                self.requestScanForActiveSession(paced: true)
            },
            onOutput: { [weak self] in
                self?.requestScanForActiveSession(paced: true)
            },
            onBindingAction: { [weak self] in
                self?.renderedFrameGate.noteGridMutation()
            }
        )
    }

    private func endActiveSession() {
        activeSession = nil
        eventSubscription?.cancel()
        eventSubscription = nil
        renderedFrameGate.reset()
        scanCoordinator.cancelSession()
        lastScannedGridJSON = nil
        lastScannedRowOffset = nil
        clearAnnotations()
    }

    private func activeSessionCandidate() -> (TerminalSurface, Workspace)? {
        guard isEnabled,
              isVisibleInUI,
              let hostedView,
              let window = hostedView.window,
              !hostedView.isHiddenOrHasHiddenAncestor,
              !hostedView.surfaceView.isHiddenOrHasHiddenAncestor,
              window.occlusionState.contains(.visible),
              let terminalSurface = hostedView.surfaceView.terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(terminalSurface.id) else {
            return nil
        }
        return (terminalSurface, workspace)
    }

    private func isEligible(_ session: TerminalInlineImageSession) -> Bool {
        guard isEnabled,
              isVisibleInUI,
              let hostedView,
              let window = hostedView.window,
              !hostedView.isHiddenOrHasHiddenAncestor,
              !hostedView.surfaceView.isHiddenOrHasHiddenAncestor,
              window.occlusionState.contains(.visible),
              let terminalSurface = hostedView.surfaceView.terminalSurface,
              terminalSurface.id == session.surfaceID,
              terminalSurface.tabId == session.workspaceID,
              let workspace = session.workspace,
              !workspace.isRemoteTerminalSurface(session.surfaceID) else {
            return false
        }
        return true
    }

    private func requestScanForActiveSession(paced: Bool = false) {
        guard let session = activeSession, isEligible(session) else {
            if activeSession != nil {
                endActiveSession()
            }
            return
        }
        scanCoordinator.request(paced: paced)
    }

    func scanCoordinatorRequest(workID: UUID) -> TerminalInlineImageScanRequest? {
        guard let activeSession,
              isEligible(activeSession),
              let workspace = activeSession.workspace,
              let hostedView,
              hostedView.bounds.width > 1,
              hostedView.bounds.height > 1,
              let terminalSurface = hostedView.surfaceView.terminalSurface,
              terminalSurface.id == activeSession.surfaceID,
              let gridJSON = terminalSurface.mobileRenderGridJSON(stateSeq: 0) else {
            lastScannedGridJSON = nil
            lastScannedRowOffset = nil
            clearAnnotations()
            return nil
        }
        let rowOffset = Int(clamping: hostedView.surfaceView.scrollbar?.offset ?? 0)
        if gridJSON == lastScannedGridJSON, rowOffset == lastScannedRowOffset {
            render()
            requestMissingThumbnails(for: annotations)
            return nil
        }
        return TerminalInlineImageScanRequest(
            workID: workID,
            sessionID: activeSession.id,
            surfaceID: activeSession.surfaceID,
            gridJSON: gridJSON,
            rowOffset: rowOffset,
            context: TerminalTranscriptImagePathScanner.Context(
                cwd: CommandClickFileOpenRouter.resolveWorkingDirectory(
                    workspace: workspace,
                    surfaceId: activeSession.surfaceID
                ),
                homeDirectory: NSHomeDirectory()
            )
        )
    }

    func scanCoordinatorApply(
        _ detected: [DetectedImagePath]?,
        request: TerminalInlineImageScanRequest
    ) {
        guard let activeSession,
              activeSession.id == request.sessionID,
              activeSession.surfaceID == request.surfaceID,
              isEligible(activeSession) else {
            return
        }
        applyScanResult(detected, request: request)
    }

    private func applyScanResult(
        _ detected: [DetectedImagePath]?,
        request: TerminalInlineImageScanRequest
    ) {
        lastScannedGridJSON = request.gridJSON
        lastScannedRowOffset = request.rowOffset
        guard let detected else {
            clearAnnotations()
            return
        }
        let nextAnnotations = reconciler.reconcile(
            existing: annotations,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: request.rowOffset)
        )
        annotations = nextAnnotations
        let liveIDs = Set(nextAnnotations.map(\.id))
        let livePaths = Set(nextAnnotations.map(\.resolvedPath))
        thumbnailsByID = thumbnailsByID.filter { liveIDs.contains($0.key) }
        thumbnailRetryAttemptByPath = thumbnailRetryAttemptByPath.filter { livePaths.contains($0.key) }
        cancelThumbnailLoads(except: livePaths)
        cancelThumbnailRetries(except: livePaths)
        render()
        requestMissingThumbnails(for: nextAnnotations)
    }

    private func requestMissingThumbnails(for annotations: [TerminalInlineImageAnnotation]) {
        guard let sessionID = activeSession?.id else { return }
        for annotation in annotations where thumbnailsByID[annotation.id] == nil {
            let path = annotation.resolvedPath
            guard thumbnailLoadTasksByPath[path] == nil else { continue }
            guard thumbnailRetryTasksByPath[path] == nil else { continue }
            guard (thumbnailRetryAttemptByPath[path] ?? 0) <= Self.maximumThumbnailRetryAttempts else {
                continue
            }
            let loadID = UUID()
            thumbnailLoadIDsByPath[path] = loadID
            let cache = cache
            thumbnailLoadTasksByPath[path] = Task { [weak self, cache, path] in
                let thumbnail = await cache.thumbnail(for: path)
                guard let self else { return }
                self.receiveThumbnail(
                    thumbnail,
                    path: path,
                    loadID: loadID,
                    sessionID: sessionID
                )
            }
        }
    }

    private func receiveThumbnail(
        _ thumbnail: TerminalInlineImageThumbnail?,
        path: String,
        loadID: UUID,
        sessionID: UUID
    ) {
        guard thumbnailLoadIDsByPath[path] == loadID else { return }
        thumbnailLoadTasksByPath.removeValue(forKey: path)
        thumbnailLoadIDsByPath.removeValue(forKey: path)
        guard activeSession?.id == sessionID else { return }
        let matchingAnnotations = annotations.filter { $0.resolvedPath == path }
        guard !matchingAnnotations.isEmpty else { return }
        guard let thumbnail else {
            rememberThumbnailFailure(for: path, sessionID: sessionID)
            return
        }
        thumbnailRetryAttemptByPath.removeValue(forKey: path)
        thumbnailRetryTasksByPath.removeValue(forKey: path)?.cancel()
        for annotation in matchingAnnotations {
            thumbnailsByID[annotation.id] = thumbnail
        }
        render()
    }

    private func rememberThumbnailFailure(for path: String, sessionID: UUID) {
        let attempt = (thumbnailRetryAttemptByPath[path] ?? 0) + 1
        thumbnailRetryAttemptByPath[path] = attempt
        guard attempt <= Self.maximumThumbnailRetryAttempts else { return }
        let retryDelay = min(
            Self.thumbnailRetryDelay * (1 << min(attempt - 1, 3)),
            Self.maximumThumbnailRetryDelay
        )
        scheduleThumbnailRetry(for: path, sessionID: sessionID, delay: retryDelay)
    }

    private func scheduleThumbnailRetry(for path: String, sessionID: UUID, delay: Duration) {
        thumbnailRetryTasksByPath[path]?.cancel()
        let sleep = retrySleep
        thumbnailRetryTasksByPath[path] = Task { @MainActor [weak self, path, sleep] in
            // This is a genuine file-appearance retry delay. It is injected for tests
            // and the stored task is cancelled whenever the surface session ends.
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.activeSession?.id == sessionID else { return }
            self.thumbnailRetryTasksByPath.removeValue(forKey: path)
            self.requestMissingThumbnails(
                for: self.annotations.filter { $0.resolvedPath == path }
            )
        }
    }

    private func render() {
        guard let activeSession,
              isEligible(activeSession),
              let hostedView,
              let overlayView else {
            overlayView?.clear()
            return
        }
        renderer.render(
            hostedView: hostedView,
            overlayView: overlayView,
            annotations: annotations,
            thumbnailsByID: thumbnailsByID
        )
    }

    private func clearAnnotations() {
        annotations.removeAll()
        thumbnailsByID.removeAll()
        thumbnailRetryAttemptByPath.removeAll()
        cancelThumbnailLoadTasks()
        cancelThumbnailRetryTasks()
        overlayView?.clear()
    }

    private func cancelThumbnailLoads(except livePaths: Set<String>) {
        let stalePaths = thumbnailLoadTasksByPath.keys.filter { !livePaths.contains($0) }
        for path in stalePaths {
            thumbnailLoadTasksByPath.removeValue(forKey: path)?.cancel()
            thumbnailLoadIDsByPath.removeValue(forKey: path)
        }
    }

    private func cancelThumbnailLoadTasks() {
        thumbnailLoadTasksByPath.values.forEach { $0.cancel() }
        thumbnailLoadTasksByPath.removeAll()
        thumbnailLoadIDsByPath.removeAll()
    }

    private func cancelThumbnailRetries(except livePaths: Set<String>) {
        let stalePaths = thumbnailRetryTasksByPath.keys.filter { !livePaths.contains($0) }
        for path in stalePaths {
            thumbnailRetryTasksByPath.removeValue(forKey: path)?.cancel()
        }
    }

    private func cancelThumbnailRetryTasks() {
        thumbnailRetryTasksByPath.values.forEach { $0.cancel() }
        thumbnailRetryTasksByPath.removeAll()
    }
}
