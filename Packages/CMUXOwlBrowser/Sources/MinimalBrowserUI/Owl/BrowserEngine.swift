import AppKit
import Darwin
import Foundation
import MinimalBrowserCore
import OwlBrowserCore
import OwlMojoBindingsGenerated
import os

private let browserEngineLogger = Logger(
    subsystem: "ai.manaflow.minimal-browser",
    category: "BrowserEngine"
)

public struct BrowserEngineTabUpdate: Equatable, Sendable {
    public let title: String
    public let url: String
    public let isLoading: Bool
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let isReady: Bool
    public let isDisconnected: Bool
}

public typealias BrowserEngineRuntimeFactory = (BrowserEngineConfiguration) throws -> any OwlBrowserRuntime

public enum BrowserEngineDevToolsPlacement: Equatable, Sendable {
    case bottom
    case right
    case left
    case window

    var mojoMode: OwlFreshDevToolsMode {
        switch self {
        case .bottom:
            return .bottom
        case .right:
            return .right
        case .left:
            return .left
        case .window:
            return .window
        }
    }

    var surfaceLabel: String {
        switch self {
        case .bottom:
            return "devtools-bottom"
        case .right:
            return "devtools-right"
        case .left:
            return "devtools-left"
        case .window:
            return "devtools-window"
        }
    }
}

public struct BrowserEngineRenderSnapshot: Equatable {
    public let tabID: BrowserTab.ID
    public let contextID: UInt32
    public let surfaceTree: OwlFreshSurfaceTree?
    public let cursor: OwlFreshCursorInfo?
    public let isReady: Bool
    public let isLoading: Bool
    public let errorMessage: String?
    public let generation: UInt64

    public var canRender: Bool {
        contextID != 0 || surfaceTree?.surfaces.contains(where: { $0.visible && $0.contextId != 0 }) == true
    }
}

public struct BrowserEngineRenderSnapshotObservation: Hashable {
    fileprivate let id: UUID
}

@MainActor
public final class BrowserEngine {
    public private(set) var renderGeneration: UInt64 = 0
    public private(set) var statusMessage: String = ""

    public var onTabUpdate: ((BrowserTab.ID, BrowserEngineTabUpdate) -> Void)?
    public var runtimeDescription: String {
        runtime?.runtimeDescription ?? ""
    }

    private let configuration: BrowserEngineConfiguration
    private let runtimeFactory: BrowserEngineRuntimeFactory?
    private var runtime: (any OwlBrowserRuntime)?
    private var initialized = false
    private var sessions: [BrowserTab.ID: BrowserEngineSession] = [:]
    private var pendingViewports: [BrowserTab.ID: BrowserViewport] = [:]
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0 / 60.0
    private let surfaceFlushInterval: TimeInterval = 1.0 / 60.0
    private let surfaceExpectationTimeout: TimeInterval
    private var renderSnapshotObservers: [UUID: BrowserEngineRenderSnapshotObserver] = [:]

    public init(
        configuration: BrowserEngineConfiguration = .fromEnvironment(),
        runtimeFactory: BrowserEngineRuntimeFactory? = nil,
        surfaceExpectationTimeout: TimeInterval
    ) {
        self.configuration = configuration
        self.runtimeFactory = runtimeFactory
        self.surfaceExpectationTimeout = surfaceExpectationTimeout
    }

    public convenience init(
        configuration: BrowserEngineConfiguration = .fromEnvironment(),
        runtimeFactory: BrowserEngineRuntimeFactory? = nil
    ) {
        self.init(
            configuration: configuration,
            runtimeFactory: runtimeFactory,
            surfaceExpectationTimeout: 5
        )
    }

    deinit {
        // Session shutdown is handled by explicit tab close and process lifetime.
        // Swift 6 deinit isolation prevents touching Timer/runtime state here.
    }

    public func start() {
        do {
            try ensureRuntimeStarted()
        } catch {
            statusMessage = String(describing: error)
            renderGeneration += 1
        }
    }

    public func hasLiveSession(tabID: BrowserTab.ID) -> Bool {
        guard let session = sessions[tabID] else {
            return false
        }
        return !session.events.snapshot().disconnected
    }

    public func isDisconnected(tabID: BrowserTab.ID) -> Bool {
        sessions[tabID]?.events.snapshot().disconnected ?? false
    }

    public func hostProcessID(tabID: BrowserTab.ID) -> Int32? {
        guard let session = sessions[tabID] else {
            return nil
        }
        let pid = session.events.snapshot().hostPID
        return pid > 0 ? pid : nil
    }

    private func existingInputSession(tabID: BrowserTab.ID) -> BrowserEngineSession? {
        guard let session = sessions[tabID],
              !session.events.snapshot().disconnected else {
            return nil
        }
        return session
    }

    public func closeTab(_ tabID: BrowserTab.ID) {
        guard let session = sessions.removeValue(forKey: tabID), let runtime else {
            return
        }
        let hostPID = session.events.snapshot().hostPID
        runtime.destroy(session.session)
        terminateHostProcessIfNeeded(pid: hostPID)
        removeOwnedProfileDirectory(for: session)
        pendingViewports[tabID] = nil
        advanceRenderGenerationAndPublish(tabIDs: [tabID])
    }

    public func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard let runtime else {
            return
        }
        for session in sessions.values {
            let hostPID = session.events.snapshot().hostPID
            runtime.destroy(session.session)
            terminateHostProcessIfNeeded(pid: hostPID)
            removeOwnedProfileDirectory(for: session)
        }
        sessions.removeAll()
        pendingViewports.removeAll()
        self.runtime = nil
        initialized = false
    }

    public func navigate(tabID: BrowserTab.ID, url: String, visibleSize: CGSize? = nil, scale: CGFloat? = nil) {
        do {
            try performNavigate(tabID: tabID, url: url, visibleSize: visibleSize, scale: scale)
        } catch where isPeerClosed(error) {
            recordPeerClosed(error: error, for: tabID, clearsLoading: true)
            do {
                try performNavigate(tabID: tabID, url: url, visibleSize: visibleSize, scale: scale)
            } catch {
                recordCommandError(error, for: tabID, clearsLoading: true)
            }
        } catch {
            recordCommandError(error, for: tabID, clearsLoading: true)
        }
    }

    private func performNavigate(tabID: BrowserTab.ID, url: String, visibleSize: CGSize?, scale: CGFloat?) throws {
        try ensureRuntimeStarted()
        let hadSession = hasLiveSession(tabID: tabID)
        let session = try ensureSession(tabID: tabID, initialURL: url)
        if let visibleSize {
            try resize(tabID: tabID, size: visibleSize, scale: scale ?? 1)
        }
        try flushPendingResize(for: session)
        if hadSession {
            try session.controller.navigate(url)
        }
        try session.controller.setFocus(true)
        requestSurfaceFlush(for: session)
        session.lastError = nil
        statusMessage = ""
        advanceRenderGenerationAndPublish(tabIDs: [tabID])
    }

    public func resize(tabID: BrowserTab.ID, size: CGSize, scale: CGFloat) throws {
        guard size.width >= 1, size.height >= 1 else {
            return
        }
        let request = OwlFreshWebViewResizeRequest(
            width: UInt32(max(1, size.width.rounded())),
            height: UInt32(max(1, size.height.rounded())),
            scale: Float(max(scale, 1))
        )
        if pendingViewports[tabID]?.request == request {
            if let session = sessions[tabID], session.pendingResizeRequest == nil {
                session.pendingResizeRequest = session.sentResizeRequest == request ? nil : request
            }
            return
        }
        pendingViewports[tabID] = BrowserViewport(request: request)
        guard let session = sessions[tabID] else {
            return
        }
        session.pendingResizeRequest = request
    }

    public func resizeImmediately(tabID: BrowserTab.ID, size: CGSize, scale: CGFloat) throws {
        try resize(tabID: tabID, size: size, scale: scale)
        guard let session = sessions[tabID] else {
            return
        }
        try flushPendingResize(for: session)
    }

    public func setFocus(tabID: BrowserTab.ID, focused: Bool) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            try session.controller.setFocus(focused)
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func activateExistingTab(_ tabID: BrowserTab.ID, previousTabID: BrowserTab.ID? = nil, focused: Bool = true) {
        if let previousTabID, previousTabID != tabID, let previous = sessions[previousTabID] {
            do {
                try previous.controller.setFocus(false)
            } catch {
                if isPeerClosed(error) {
                    recordPeerClosed(error: error, for: previousTabID)
                } else {
                    previous.lastError = String(describing: error)
                }
            }
        }
        guard let session = sessions[tabID] else {
            return
        }
        do {
            try session.controller.setFocus(focused)
            requestSurfaceFlush(for: session)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func sendMouse(tabID: BrowserTab.ID, event: OwlFreshMouseEvent) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            switch event.kind {
            case .move:
                try flushPendingInput(for: session)
                try session.controller.sendMouse(event)
                pollRuntime()
            case .wheel:
                try flushPendingInput(for: session)
                try session.controller.sendWheel(OwlFreshWheelEvent(
                    x: event.x,
                    y: event.y,
                    deltaX: event.deltaX,
                    deltaY: event.deltaY,
                    wheelTicksX: event.deltaX / 40,
                    wheelTicksY: event.deltaY / 40,
                    phase: 0,
                    momentumPhase: 0,
                    modifiers: event.modifiers,
                    deltaUnits: 1
                ))
            case .down:
                try flushPendingInput(for: session)
                try session.controller.sendMouse(event)
                try publishNativeSurfaceTreeAfterMouseButtonEvent(for: session)
            case .up:
                try flushPendingInput(for: session)
                try session.controller.sendMouse(event)
                try publishNativeSurfaceTreeAfterMouseButtonEvent(for: session)
            }
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func sendWheel(tabID: BrowserTab.ID, event: OwlFreshWheelEvent) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            try flushPendingInput(for: session)
            try session.controller.sendWheel(event)
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func sendKey(tabID: BrowserTab.ID, event: OwlFreshKeyEvent) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            let controller = session.controller
            try flushPendingInput(for: session)
            try controller.sendKey(event)
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func executeEditCommand(tabID: BrowserTab.ID, command: String) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            let controller = session.controller
            try flushPendingInput(for: session)
            try controller.executeEditCommand(command)
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func sendComposition(tabID: BrowserTab.ID, event: OwlFreshCompositionEvent) {
        do {
            guard let session = existingInputSession(tabID: tabID) else {
                return
            }
            let controller = session.controller
            try flushPendingInput(for: session)
            try controller.sendComposition(event)
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func goBack(tabID: BrowserTab.ID) {
        do {
            try ensureSession(tabID: tabID, initialURL: "about:blank").controller.goBack()
            requestSurfaceFlush(for: tabID)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func goForward(tabID: BrowserTab.ID) {
        do {
            try ensureSession(tabID: tabID, initialURL: "about:blank").controller.goForward()
            requestSurfaceFlush(for: tabID)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func reload(tabID: BrowserTab.ID) {
        do {
            try ensureSession(tabID: tabID, initialURL: "about:blank").controller.reload()
            requestSurfaceFlush(for: tabID)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID, clearsLoading: true)
        }
    }

    public func stopLoading(tabID: BrowserTab.ID) {
        do {
            try ensureSession(tabID: tabID, initialURL: "about:blank").controller.stopLoading()
            requestSurfaceFlush(for: tabID)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func openDevTools(tabID: BrowserTab.ID, placement: BrowserEngineDevToolsPlacement) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            if session.activeDevToolsPlacement == placement {
                requestSurfaceFlush(for: session, expectation: .devTools(label: placement.surfaceLabel))
                pollRuntime()
                return
            }
            let opened = try session.controller.openDevTools(placement.mojoMode)
            guard opened else {
                throw BrowserEngineError.commandRejected("Chromium rejected Open DevTools \(placement)")
            }
            browserEngineLogger.info("Open DevTools accepted placement=\(String(describing: placement), privacy: .public)")
            session.activeDevToolsPlacement = placement
            requestSurfaceFlush(for: session, expectation: .devTools(label: placement.surfaceLabel))
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func closeDevTools(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            let closed = try session.controller.closeDevTools()
            guard closed else {
                throw BrowserEngineError.commandRejected("Chromium rejected Close DevTools")
            }
            browserEngineLogger.info("Close DevTools accepted")
            session.activeDevToolsPlacement = nil
            requestSurfaceFlush(for: session, expectation: .noDevTools)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func evaluateDevToolsJavaScript(tabID: BrowserTab.ID, script: String) throws -> String {
        let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
        return try session.controller.evaluateDevToolsJavaScript(script)
    }

    public func hostLogs(tabID: BrowserTab.ID) -> [String] {
        sessions[tabID]?.events.snapshot().logs ?? []
    }

    public func flush(tabID: BrowserTab.ID) throws -> Bool {
        let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
        guard let runtime else {
            throw BrowserEngineError.notStarted
        }
        try flushPendingSessionWork(for: session)
        let flushed = try runtime.sessionFlush(session.session)
        session.nextSurfaceFlushAt = Date().addingTimeInterval(surfaceFlushInterval)
        let changed = session.surfaceTreeExpectation != nil
            ? refreshExpectedSurfaceTreeIfNeeded(for: session, now: Date())
            : false
        if flushed {
            pollRuntime()
        } else if changed {
            advanceRenderGenerationAndPublish(tabIDs: [tabID])
        }
        return flushed
    }

    @discardableResult
    public func addRenderSnapshotObserver(
        for tabID: BrowserTab.ID,
        _ handler: @escaping @MainActor (BrowserEngineRenderSnapshot) -> Void
    ) -> BrowserEngineRenderSnapshotObservation {
        let token = BrowserEngineRenderSnapshotObservation(id: UUID())
        renderSnapshotObservers[token.id] = BrowserEngineRenderSnapshotObserver(
            tabID: tabID,
            handler: handler
        )
        handler(snapshot(for: tabID))
        return token
    }

    public func updateRenderSnapshotObserver(
        _ observation: BrowserEngineRenderSnapshotObservation,
        tabID: BrowserTab.ID
    ) {
        guard let observer = renderSnapshotObservers[observation.id],
              observer.tabID != tabID else {
            return
        }
        renderSnapshotObservers[observation.id] = BrowserEngineRenderSnapshotObserver(
            tabID: tabID,
            handler: observer.handler
        )
        observer.handler(snapshot(for: tabID))
    }

    public func removeRenderSnapshotObserver(_ observation: BrowserEngineRenderSnapshotObservation) {
        renderSnapshotObservers[observation.id] = nil
    }

    public func acceptActivePopupMenuItem(tabID: BrowserTab.ID, index: UInt32) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.acceptActivePopupMenuItem(index)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func cancelActivePopup(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.cancelActivePopup()
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func selectActiveFilePickerFiles(tabID: BrowserTab.ID, paths: [String]) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.selectActiveFilePickerFiles(paths)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func cancelActiveFilePicker(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.cancelActiveFilePicker()
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func acceptActivePermissionPrompt(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.acceptActivePermissionPrompt()
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func cancelActivePermissionPrompt(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.cancelActivePermissionPrompt()
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func submitActiveAuthPrompt(tabID: BrowserTab.ID, username: String, password: String) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.submitActiveAuthPrompt(username: username, password: password)
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func cancelActiveAuthPrompt(tabID: BrowserTab.ID) {
        do {
            let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
            _ = try session.controller.cancelActiveAuthPrompt()
            pollRuntime()
        } catch {
            recordCommandError(error, for: tabID)
        }
    }

    public func snapshot(for tabID: BrowserTab.ID) -> BrowserEngineRenderSnapshot {
        guard let session = sessions[tabID] else {
            return BrowserEngineRenderSnapshot(
                tabID: tabID,
                contextID: 0,
                surfaceTree: nil,
                cursor: nil,
                isReady: initialized,
                isLoading: false,
                errorMessage: statusMessage.isEmpty ? nil : statusMessage,
                generation: renderGeneration
            )
        }
        let eventSnapshot = session.events.snapshot()
        return BrowserEngineRenderSnapshot(
            tabID: tabID,
            contextID: session.contextID != 0 ? session.contextID : eventSnapshot.contextID,
            surfaceTree: session.surfaceTree ?? eventSnapshot.surfaceTree,
            cursor: session.cursor ?? eventSnapshot.cursor,
            isReady: eventSnapshot.ready,
            isLoading: eventSnapshot.loading,
            errorMessage: session.lastError,
            generation: renderGeneration
        )
    }

    public func captureSurfacePNG(tabID: BrowserTab.ID, to url: URL) throws -> OwlBrowserSurfaceCapture {
        let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
        return try runtime?.captureSurfacePNG(session.session, to: url)
            ?? {
                throw BrowserEngineError.notStarted
            }()
    }

    public func captureSurfacePNG(tabID: BrowserTab.ID, label: String, to url: URL) throws -> OwlBrowserSurfaceCapture {
        let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
        return try runtime?.captureSurfacePNG(session.session, label: label, to: url)
            ?? {
                throw BrowserEngineError.notStarted
            }()
    }

    public func executeJavaScript(tabID: BrowserTab.ID, script: String) throws -> String {
        let session = try ensureSession(tabID: tabID, initialURL: "about:blank")
        guard let runtime else {
            throw BrowserEngineError.notStarted
        }
        return try runtime.executeJavaScript(session.session, script: script)
    }

    public func profileDirectory(tabID: BrowserTab.ID) throws -> String {
        try ensureSession(tabID: tabID, initialURL: "about:blank").profileDirectory
    }

    public func runtimeProfilePath(tabID: BrowserTab.ID) throws -> String {
        try ensureSession(tabID: tabID, initialURL: "about:blank").controller.profilePath()
    }

    private func bootstrapRuntime() throws {
        guard configuration.isConfigured else {
            throw BrowserEngineError.missingRuntime(
                "Missing OWL runtime. Rebuild the app bundle so it includes Contents/Resources/Chromium, or set MINIMAL_BROWSER_CHROMIUM_HOST and MINIMAL_BROWSER_MOJO_RUNTIME_PATH."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.chromiumHostPath) else {
            throw BrowserEngineError.missingRuntime("Chromium host is not executable: \(configuration.chromiumHostPath)")
        }
        guard FileManager.default.fileExists(atPath: configuration.mojoRuntimePath) else {
            throw BrowserEngineError.missingRuntime("Mojo runtime dylib does not exist: \(configuration.mojoRuntimePath)")
        }
        guard let runtimeFactory else {
            throw BrowserEngineError.missingRuntime("No OWL runtime factory was configured.")
        }
        let runtime = try runtimeFactory(configuration)
        try runtime.initialize()
        self.runtime = runtime
    }

    private func ensureRuntimeStarted() throws {
        guard initialized == false else {
            return
        }
        try bootstrapRuntime()
        initialized = true
        statusMessage = ""
        startPolling()
    }

    private func ensureSession(tabID: BrowserTab.ID, initialURL: String) throws -> BrowserEngineSession {
        if let session = sessions[tabID] {
            if session.events.snapshot().disconnected {
                discardSession(session)
            } else {
                return session
            }
        }
        guard let runtime else {
            if !statusMessage.isEmpty {
                throw BrowserEngineError.missingRuntime(statusMessage)
            }
            throw BrowserEngineError.notStarted
        }
        applySessionLaunchEnvironment()
        try FileManager.default.createDirectory(
            atPath: configuration.userDataRootPath,
            withIntermediateDirectories: true
        )
        let profileDirectory = "\(configuration.userDataRootPath)/\(tabID.uuidString)"
        try FileManager.default.createDirectory(
            atPath: profileDirectory,
            withIntermediateDirectories: true
        )
        let events = OwlBrowserSessionEvents()
        let session = try runtime.createSession(
            chromiumHost: configuration.chromiumHostPath,
            initialURL: initialURL,
            userDataDirectory: profileDirectory,
            events: events
        )
        let controller = try OwlBrowserSessionController(pipe: runtime, session: session)
        let browserSession = BrowserEngineSession(
            tabID: tabID,
            session: session,
            controller: controller,
            events: events,
            profileDirectory: profileDirectory
        )
        sessions[tabID] = browserSession
        if let viewport = pendingViewports[tabID] {
            browserSession.pendingResizeRequest = viewport.request
        }
        return browserSession
    }

    private func applySessionLaunchEnvironment() {
        guard configuration.devToolsEnabled else {
            return
        }
        if getenv("OWL_FRESH_ENABLE_DEVTOOLS") == nil {
            setenv("OWL_FRESH_ENABLE_DEVTOOLS", "1", 1)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollRuntime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollRuntime() {
        guard let runtime else {
            return
        }
        var changedTabIDs = Set<BrowserTab.ID>()
        if flushPendingSessionWork() {
            changedTabIDs.formUnion(sessions.keys)
        }
        if flushSurfaceTreesIfNeeded(runtime: runtime) {
            changedTabIDs.formUnion(sessions.keys)
        }
        runtime.pollEvents(milliseconds: 0)
        for session in sessions.values {
            let snapshot = session.events.snapshot()
            if snapshot.disconnected {
                if session.lastError == nil {
                    session.lastError = L10n.string(
                        "page.status.disconnected",
                        defaultValue: "Browser engine disconnected"
                    )
                }
                session.surfaceTreeExpectation = nil
                changedTabIDs.insert(session.tabID)
            }
            if snapshot.contextID != 0, snapshot.contextID != session.contextID {
                session.contextID = snapshot.contextID
                changedTabIDs.insert(session.tabID)
            }
            if let surfaceTree = snapshot.surfaceTree, surfaceTree != session.surfaceTree {
                let shouldPublishSurfaceTree = shouldPublish(surfaceTree: surfaceTree, for: session)
                if shouldPublishSurfaceTree {
                    session.surfaceTree = surfaceTree
                    changedTabIDs.insert(session.tabID)
                }
                if session.surfaceTreeExpectation?.isSatisfied(by: surfaceTree) == true {
                    session.surfaceTreeExpectation = nil
                }
            }
            if snapshot.cursor != session.cursor {
                session.cursor = snapshot.cursor
                changedTabIDs.insert(session.tabID)
            }
            let update = BrowserEngineTabUpdate(
                title: snapshot.title,
                url: snapshot.url,
                isLoading: snapshot.loading,
                canGoBack: snapshot.canGoBack,
                canGoForward: snapshot.canGoForward,
                isReady: snapshot.ready,
                isDisconnected: snapshot.disconnected
            )
            if update != session.lastUpdate {
                session.lastUpdate = update
                onTabUpdate?(session.tabID, update)
                changedTabIDs.insert(session.tabID)
            }
        }
        advanceRenderGenerationAndPublish(tabIDs: changedTabIDs)
    }

    func pollRuntimeForTesting() {
        pollRuntime()
    }

    public func pollNowForAutomation() {
        pollRuntime()
    }

    public func pollNowForHostGeometry() {
        pollRuntime()
    }

    private func requestSurfaceFlush(for tabID: BrowserTab.ID) {
        guard let session = sessions[tabID] else {
            return
        }
        requestSurfaceFlush(for: session)
    }

    private func requestSurfaceFlush(
        for session: BrowserEngineSession,
        expectation: BrowserSurfaceTreeExpectation? = nil
    ) {
        if let expectation {
            session.nextSurfaceFlushAt = .distantPast
            session.surfaceTreeExpectation = expectation
            session.surfaceTreeExpectationDeadline = Date().addingTimeInterval(surfaceExpectationTimeout)
        }
    }

    private func flushSurfaceTreesIfNeeded(runtime: any OwlBrowserRuntime) -> Bool {
        let now = Date()
        var changed = false
        for session in Array(sessions.values) where
            sessions[session.tabID] === session &&
            session.surfaceTreeExpectation != nil &&
            now >= session.nextSurfaceFlushAt {
            session.nextSurfaceFlushAt = now.addingTimeInterval(surfaceFlushInterval)
            do {
                let flushed = try runtime.sessionFlush(session.session)
                OwlGeometryDebugLogger.record("engine.surfaceFlush", fields: [
                    "tabID": session.tabID.uuidString,
                    "flushed": OwlGeometryDebugLogger.bool(flushed),
                    "expectation": session.surfaceTreeExpectation?.description ?? "none"
                ])
                if session.surfaceTreeExpectation != nil {
                    changed = refreshExpectedSurfaceTreeIfNeeded(for: session, now: now) || changed
                } else if flushed {
                    changed = true
                }
            } catch {
                recordCommandError(error, for: session.tabID)
                changed = true
            }
        }
        return changed
    }

    private func flushPendingSessionWork() -> Bool {
        var changed = false
        for session in Array(sessions.values) where sessions[session.tabID] === session {
            do {
                try flushPendingSessionWork(for: session)
            } catch {
                recordCommandError(error, for: session.tabID)
                changed = true
            }
        }
        return changed
    }

    private func flushPendingSessionWork(for session: BrowserEngineSession) throws {
        try flushPendingResize(for: session)
        try flushPendingInput(for: session)
    }

    private func flushPendingResize(for session: BrowserEngineSession) throws {
        guard let request = session.pendingResizeRequest else {
            return
        }
        if session.sentResizeRequest != request {
            try session.controller.resize(request)
            session.sentResizeRequest = request
            requestSurfaceFlush(
                for: session,
                expectation: .webView(width: request.width, height: request.height)
            )
        }
        session.pendingResizeRequest = nil
        pendingViewports[session.tabID] = BrowserViewport(request: request)
    }

    private func queueMouseMove(_ event: OwlFreshMouseEvent, for session: BrowserEngineSession) {
        session.pendingMouseMove = event
        session.enqueueInput(.mouseMove)
    }

    private func flushPendingInput(for session: BrowserEngineSession) throws {
        while let kind = session.dequeueInput() {
            switch kind {
            case .mouseMove:
                if let event = session.pendingMouseMove {
                    session.pendingMouseMove = nil
                    try session.controller.sendMouse(event)
                }
            }
        }
    }

    private func refreshExpectedSurfaceTreeIfNeeded(for session: BrowserEngineSession, now: Date) -> Bool {
        guard let expectation = session.surfaceTreeExpectation else {
            return false
        }
        let timedOut = now > session.surfaceTreeExpectationDeadline
        do {
            let tree = try session.controller.getSurfaceTree()
            let isSatisfied = expectation.isSatisfied(by: tree)
            let shouldPublishSurfaceTree = shouldPublish(surfaceTree: tree, for: session)
            let changed = (timedOut || shouldPublishSurfaceTree) && tree != session.surfaceTree
            if timedOut || shouldPublishSurfaceTree {
                session.surfaceTree = tree
            }
            browserEngineLogger.info(
                "Refreshed surface tree expectation=\(expectation.description, privacy: .public) generation=\(tree.generation) surfaces=\(surfaceSummary(tree), privacy: .public)"
            )
            if timedOut || isSatisfied {
                session.surfaceTreeExpectation = nil
            }
            if timedOut && !isSatisfied {
                browserEngineLogger.info(
                    "Surface expectation timed out for \(expectation.description, privacy: .public); publishing latest surface tree instead"
                )
            }
            return changed
        } catch {
            if isPeerClosed(error) {
                recordPeerClosed(error: error, for: session.tabID)
                return true
            }
            if timedOut {
                session.surfaceTreeExpectation = nil
                browserEngineLogger.error(
                    "Surface expectation timed out for \(expectation.description, privacy: .public), and latest surface tree fetch failed: \(String(describing: error), privacy: .public)"
                )
            } else {
                session.lastError = String(describing: error)
            }
            return !timedOut
        }
    }

    private func publishNativeSurfaceTreeAfterMouseButtonEvent(for session: BrowserEngineSession) throws {
        let tree = try session.controller.getSurfaceTree()
        guard tree.hasVisibleNativeSurface || session.surfaceTree?.hasVisibleNativeSurface == true else {
            return
        }
        let shouldPublishSurfaceTree = shouldPublish(surfaceTree: tree, for: session)
        guard shouldPublishSurfaceTree, tree != session.surfaceTree else {
            return
        }
        session.surfaceTree = tree
        browserEngineLogger.info(
            "Refreshed surface tree after mouse button event generation=\(tree.generation) surfaces=\(surfaceSummary(tree), privacy: .public)"
        )
        advanceRenderGenerationAndPublish(tabIDs: [session.tabID])
    }

    private func shouldPublish(surfaceTree: OwlFreshSurfaceTree, for session: BrowserEngineSession) -> Bool {
        if surfaceTree.hasVisibleNativeSurface {
            return true
        }
        guard let expectation = session.surfaceTreeExpectation else {
            return true
        }
        return session.surfaceTree == nil || expectation.isSatisfied(by: surfaceTree)
    }

    private func discardSession(_ session: BrowserEngineSession) {
        guard sessions[session.tabID] === session else {
            return
        }
        sessions[session.tabID] = nil
        let hostPID = session.events.snapshot().hostPID
        runtime?.destroy(session.session)
        terminateHostProcessIfNeeded(pid: hostPID)
        removeOwnedProfileDirectory(for: session)
        advanceRenderGenerationAndPublish(tabIDs: [session.tabID])
    }

    private func removeOwnedProfileDirectory(for session: BrowserEngineSession) {
        let rootURL = URL(fileURLWithPath: configuration.userDataRootPath)
            .standardizedFileURL
        let profileURL = URL(fileURLWithPath: session.profileDirectory)
            .standardizedFileURL
        guard !rootURL.path.isEmpty,
              profileURL.path.hasPrefix(rootURL.path + "/"),
              profileURL.lastPathComponent == session.tabID.uuidString else {
            browserEngineLogger.error(
                "Refusing to remove profile outside owned root profile=\(profileURL.path, privacy: .public) root=\(rootURL.path, privacy: .public)"
            )
            return
        }
        do {
            try FileManager.default.removeItemIfPresent(at: profileURL)
        } catch {
            browserEngineLogger.error(
                "Failed to remove profile directory \(profileURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func recordCommandError(_ error: Error, for tabID: BrowserTab.ID, clearsLoading: Bool = false) {
        if isPeerClosed(error) {
            recordPeerClosed(error: error, for: tabID, clearsLoading: clearsLoading)
            return
        }
        record(error: error, for: tabID, clearsLoading: clearsLoading)
    }

    private func recordPeerClosed(error: Error, for tabID: BrowserTab.ID, clearsLoading: Bool = false) {
        browserEngineLogger.error(
            "Mojo peer closed for tab=\(tabID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        let message = disconnectedMessage()
        let session = sessions[tabID]
        session?.lastError = message
        session?.surfaceTreeExpectation = nil
        statusMessage = message
        if let session {
            discardSession(session)
        }
        if clearsLoading {
            publishErrorTabUpdate(for: tabID, session: nil)
        }
        advanceRenderGenerationAndPublish(tabIDs: [tabID])
    }

    private func record(error: Error, for tabID: BrowserTab.ID, clearsLoading: Bool = false) {
        let message = String(describing: error)
        let session = sessions[tabID]
        session?.lastError = message
        statusMessage = message
        if clearsLoading {
            publishErrorTabUpdate(for: tabID, session: session)
        }
        advanceRenderGenerationAndPublish(tabIDs: [tabID])
    }

    private func isPeerClosed(_ error: Error) -> Bool {
        OwlBrowserRuntimeErrorClassifier.isPeerClosed(error)
    }

    private func disconnectedMessage() -> String {
        L10n.string(
            "page.status.disconnected",
            defaultValue: "Browser engine disconnected"
        )
    }

    private func advanceRenderGenerationAndPublish(tabIDs: some Sequence<BrowserTab.ID>) {
        let changedTabIDs = Set(tabIDs)
        guard !changedTabIDs.isEmpty else {
            return
        }
        renderGeneration += 1
        publishRenderSnapshots(for: changedTabIDs)
    }

    private func publishRenderSnapshots(for tabIDs: Set<BrowserTab.ID>) {
        guard !renderSnapshotObservers.isEmpty else {
            return
        }
        for observer in renderSnapshotObservers.values where tabIDs.contains(observer.tabID) {
            observer.handler(snapshot(for: observer.tabID))
        }
    }

    private func publishErrorTabUpdate(for tabID: BrowserTab.ID, session: BrowserEngineSession?) {
        let previousUpdate = session?.lastUpdate
        let eventSnapshot = session?.events.snapshot()
        let canGoBack = previousUpdate?.canGoBack ?? eventSnapshot?.canGoBack ?? false
        let canGoForward = previousUpdate?.canGoForward ?? eventSnapshot?.canGoForward ?? false
        let isReady = eventSnapshot?.ready ?? initialized
        let runtimeIsMissing = runtime == nil
        let isDisconnected = eventSnapshot?.disconnected ?? runtimeIsMissing
        let update = BrowserEngineTabUpdate(
            title: previousUpdate?.title ?? "",
            url: previousUpdate?.url ?? "",
            isLoading: false,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            isReady: isReady,
            isDisconnected: isDisconnected
        )
        session?.lastUpdate = update
        onTabUpdate?(tabID, update)
    }
}

private struct BrowserEngineRenderSnapshotObserver {
    let tabID: BrowserTab.ID
    let handler: @MainActor (BrowserEngineRenderSnapshot) -> Void
}

private func surfaceSummary(_ tree: OwlFreshSurfaceTree) -> String {
    tree.surfaces
        .filter(\.visible)
        .map { surface in
            "\(surface.label):\(surface.kind)@\(surface.x),\(surface.y) \(surface.width)x\(surface.height) ctx=\(surface.contextId)"
        }
        .joined(separator: ";")
}

private extension OwlFreshSurfaceTree {
    var hasVisibleNativeSurface: Bool {
        surfaces.contains {
            $0.visible && (
                $0.kind == .nativeMenu ||
                $0.kind == .nativeFilePicker ||
                $0.kind == .nativePermissionPrompt ||
                $0.kind == .nativeAuthPrompt
            )
        }
    }
}

private final class BrowserEngineSession {
    let tabID: BrowserTab.ID
    let session: OwlFreshMojoSessionHandle
    let controller: OwlBrowserSessionController
    let events: OwlBrowserSessionEvents
    let profileDirectory: String
    var contextID: UInt32 = 0
    var surfaceTree: OwlFreshSurfaceTree?
    var lastError: String?
    var lastUpdate: BrowserEngineTabUpdate?
    var nextSurfaceFlushAt: Date = .distantPast
    var surfaceTreeExpectation: BrowserSurfaceTreeExpectation?
    var surfaceTreeExpectationDeadline: Date = .distantPast
    var activeDevToolsPlacement: BrowserEngineDevToolsPlacement?
    var pendingResizeRequest: OwlFreshWebViewResizeRequest?
    var sentResizeRequest: OwlFreshWebViewResizeRequest?
    var cursor: OwlFreshCursorInfo?
    var pendingMouseMove: OwlFreshMouseEvent?
    private var pendingInputOrder: [BrowserPendingInputKind] = []

    init(
        tabID: BrowserTab.ID,
        session: OwlFreshMojoSessionHandle,
        controller: OwlBrowserSessionController,
        events: OwlBrowserSessionEvents,
        profileDirectory: String
    ) {
        self.tabID = tabID
        self.session = session
        self.controller = controller
        self.events = events
        self.profileDirectory = profileDirectory
    }

    func enqueueInput(_ kind: BrowserPendingInputKind) {
        if !pendingInputOrder.contains(kind) {
            pendingInputOrder.append(kind)
        }
    }

    func dequeueInput() -> BrowserPendingInputKind? {
        pendingInputOrder.isEmpty ? nil : pendingInputOrder.removeFirst()
    }
}

private struct BrowserViewport {
    let request: OwlFreshWebViewResizeRequest
}

private enum BrowserPendingInputKind: Equatable {
    case mouseMove
}

private enum BrowserEngineError: Error, CustomStringConvertible {
    case missingRuntime(String)
    case commandRejected(String)
    case notStarted

    var description: String {
        switch self {
        case .missingRuntime(let message):
            return message
        case .commandRejected(let message):
            return message
        case .notStarted:
            return "Browser engine has not started"
        }
    }
}

private enum BrowserSurfaceTreeExpectation: CustomStringConvertible {
    case webView(width: UInt32, height: UInt32)
    case devTools(label: String)
    case noDevTools

    var description: String {
        switch self {
        case .webView(let width, let height):
            return "web-view surface \(width)x\(height)"
        case .devTools(let label):
            return "surface \(label)"
        case .noDevTools:
            return "DevTools surfaces to close"
        }
    }

    func isSatisfied(by tree: OwlFreshSurfaceTree) -> Bool {
        switch self {
        case .webView(let width, let height):
            return tree.surfaces.contains {
                $0.visible &&
                    $0.kind == .webView &&
                    $0.label == "web-view" &&
                    $0.contextId != 0 &&
                    $0.width == width &&
                    $0.height == height
            }
        case .devTools(let label):
            return tree.surfaces.contains {
                $0.visible && $0.kind == .devTools && $0.label == label && $0.contextId != 0
            }
        case .noDevTools:
            return !tree.surfaces.contains {
                $0.visible && $0.kind == .devTools
            }
        }
    }
}

private func terminateHostProcessIfNeeded(pid: Int32) {
    guard pid > 0 else {
        return
    }
    kill(pid, SIGTERM)
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }
        try removeItem(at: url)
    }
}
