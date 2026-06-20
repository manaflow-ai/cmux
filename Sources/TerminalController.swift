import AppKit
import CmuxRemoteSession
import CmuxCore
import CmuxAuthRuntime
import CmuxFeedback
import CmuxBrowser
import CmuxControlSocket
import CmuxFoundation
import CmuxPanes
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import CmuxTerminal
import CmuxSettings
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXAgentLaunch
import Foundation
import Bonsplit
import WebKit
import CmuxSidebar
import CmuxWorkspaces

extension Notification.Name {
    static let socketListenerDidStart = Notification.Name("cmux.socketListenerDidStart")
    // terminalSurfaceDidBecomeReady moved to CmuxTerminal (posted by TerminalSurface).
    static let terminalSurfaceHostedViewDidMoveToWindow = Notification.Name("cmux.terminalSurfaceHostedViewDidMoveToWindow")
    static let mainWindowContextsDidChange = Notification.Name("cmux.mainWindowContextsDidChange")
    static let browserDownloadEventDidArrive = Notification.Name("cmux.browserDownloadEventDidArrive")
    static let reactGrabDidCopySelection = Notification.Name("cmux.reactGrabDidCopySelection")
}

nonisolated private struct SocketLineProcessingResult: Sendable {
    let response: String?
    let authenticated: Bool
}

nonisolated func remotePTYSessionListErrorIsUnsupportedDaemon(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == "cmux.remote.daemon.rpc", nsError.code == 14 else {
        return false
    }
    return error.localizedDescription
        .range(of: "pty.list failed (method_not_found)", options: [.caseInsensitive]) != nil
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
@MainActor
class TerminalController {
    static let shared = TerminalController()

    // `internal` (not `private`): the `workspace.remote.pty_*` worker-lane
    // availability wait + notify live in the sibling extension file
    // `TerminalController+ControlRemotePTYReading.swift` (the resolution seam that
    // backs `ControlRemotePTYWorker`), which cannot reach a `private` member.
    nonisolated let remotePTYControllerAvailabilityCondition = NSCondition()
    nonisolated(unsafe) var remotePTYControllerAvailabilityGeneration: UInt64 = 0
    var tabManager: TabManager?
    /// The shared auth coordinator + browser sign-in flow, injected once via
    /// `attachAuth` at app startup (AppDelegate `configure`) before the socket
    /// listener starts. Socket auth commands read these on the main actor.
    @MainActor private(set) var authCoordinator: AuthCoordinator?
    @MainActor private(set) var browserSignInFlow: HostBrowserSignInFlow?
    @MainActor var agentChatTranscriptService: AgentChatTranscriptService?
    // Sendable value type; injected at construction so socket auth never reaches a global.
    private nonisolated let passwordStore: SocketControlPasswordStore
    /// Process-wide proxy-tunnel broker (one shared tunnel per remote transport across all
    /// windows), constructed at this app-hub composition point and injected into each
    /// `WorkspaceRemoteSessionController`; ownership moves to the composition root with the
    /// planned `RemoteSessionCoordinator` wiring.
    nonisolated let remoteProxyBroker: any RemoteProxyBrokering
    // Stateless Sendable structs from CmuxControlSocket; injected at construction.
    // `transport` is internal so sibling-file extensions (CmuxEventStream) can write through it.
    nonisolated let transport: SocketTransport
    // The package-owned listener: path/bind/lock lifecycle, accept source,
    // backoff/rearm recovery, and the generation-counted state machine.
    nonisolated let socketServer: SocketControlServer
    // Accepted-connection consumer; runs until process exit (singleton).
    private nonisolated let socketConnectionsTask: Task<Void, Never>
    // Per-surface dedupe for high-frequency report_* socket telemetry. Main-
    // isolated: after the 3c cutover its only callers are the @MainActor
    // sidebar/surface seam conformances (the worker-thread fast path retired
    // with the legacy dispatcher), so the former `nonisolated` is gone. The
    // package type keeps its internal lock for its own tested contract.
    let socketFastPathState = SocketFastPathState()
    // Stateless sidebar-metadata/command argument parser (CmuxSidebar).
    // Pure transforms over the raw arg string; holds no state and reaches no
    // app singletons, so the `report_*`/sidebar-mutation handlers forward to it.
    private nonisolated let sidebarMetadataArgumentParser = SidebarMetadataArgumentParser()
    private nonisolated static let socketCommandFocusAllowanceStackKey = "cmux.socketCommandFocusAllowanceStack"
    private nonisolated static let socketListenerFailureCaptureCooldown: TimeInterval = 60
    private nonisolated static let v2BrowserDownloadWaitDefaultTimeoutMs = 10_000
    private nonisolated static let v2BrowserDownloadWaitMaxTimeoutMs = 120_000
    private nonisolated static let socketListenerFailureCaptureLock = NSLock()
    private nonisolated(unsafe) static var socketListenerFailureLastCapturedAt: [String: Date] = [:]
    private struct MobileViewportReport {
        var columns: Int
        var rows: Int
        var updatedAt: Date
        /// Sticky reports come from the dedicated `mobile.terminal.viewport`
        /// RPC and live for the client's connection lifetime (cleared on
        /// disconnect or surface detach), so an idle paired device keeps its
        /// viewport border. Non-sticky reports piggyback on `terminal.input`
        /// and expire on the TTL so a client that only ever typed once does
        /// not pin the grid forever.
        var sticky: Bool = false
    }
    private static let mobileViewportReportTTL: TimeInterval = 5
    private var mobileViewportReportsBySurfaceID: [UUID: [String: MobileViewportReport]] = [:]
    private var mobileViewportReportCleanupTimersBySurfaceID: [UUID: DispatchSourceTimer] = [:]
#if DEBUG
    private nonisolated static let socketCommandDebugLogEnvironmentKey = "CMUX_DEBUG_SOCKET_COMMAND_LOG"
    private nonisolated static let socketCommandSlowThresholdMs: Double = 500
#endif
    static var terminalProcessExitedMessage: String {
        String(
            localized: "socket.terminal.processExited",
            defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
        )
    }

    static var terminalInputQueueFullMessage: String {
        String(
            localized: "socket.terminal.inputQueueFull",
            defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
        )
    }

    static var terminalSurfaceUnavailableMessage: String {
        String(
            localized: "socket.terminal.surfaceUnavailable",
            defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
        )
    }

    static var terminalProcessExitedSocketError: String {
        "ERROR: \(terminalProcessExitedMessage)"
    }

    static var terminalInputQueueFullSocketError: String {
        "ERROR: \(terminalInputQueueFullMessage)"
    }

    static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }

    private nonisolated static let focusIntentV1Commands: Set<String> = [
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app",
        "debug_right_sidebar_focus",
    ]

    private nonisolated static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.group.focus",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "file.open",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "notification.open",
        "notification.jump_to_unread",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate",
        "debug.right_sidebar.focus",
        "feed.jump"
    ]

    /// The main-actor RPC dispatch coordinator (CmuxControlSocket). Owns the
    /// `kind:N` handle registry and the moved command domains (window so far,
    /// growing per stage-3c sub-stage); this controller is its interim
    /// composition owner and ``ControlCommandContext`` conformer. Constructed in
    /// `init`; its `context` is wired to `self` once `self` is available.
    let controlCommandCoordinator = ControlCommandCoordinator()

    /// The worker-lane `auth.*` RPC handler (CmuxControlSocket), reading live
    /// auth state through the ``AuthStatusReading`` seam conformed over this
    /// controller's `authCoordinator` / `browserSignInFlow`. Built in `init`
    /// once `self` is available (the seam conformer holds `self` weakly). Read
    /// from the nonisolated socket-worker lane, so stored `nonisolated`.
    nonisolated(unsafe) var controlAuthWorker: ControlAuthWorker?

    /// The worker-lane `sidebar.custom.*` RPC handler (CmuxControlSocket),
    /// reaching the `CmuxSwiftRenderUI` validator + the reload notification +
    /// the app's `CmuxExtensionSidebarSelection` strictly through the
    /// ``ControlSidebarCustomReading`` seam. The seam conformer holds no live
    /// app state (it reads statics and posts notifications), so it is a plain
    /// `Sendable` value; the worker can be built eagerly. Read from the
    /// nonisolated socket-worker lane, so stored `nonisolated`.
    nonisolated(unsafe) var controlSidebarCustomWorker = ControlSidebarCustomWorker(
        reading: TerminalControllerSidebarCustomReading()
    )

    /// The worker-lane `remote.tmux.*` RPC handler (CmuxControlSocket), reaching
    /// the `@MainActor` `RemoteTmuxController` (via `AppDelegate.shared`) and the
    /// `RemoteTmuxController.isEnabled` beta flag strictly through the
    /// ``ControlRemoteTmuxReading`` seam conformed by
    /// ``TerminalControllerRemoteTmuxReading``. The seam conformer holds no live
    /// `TerminalController` state (it reads statics and hops to main per call),
    /// so it is a plain `Sendable` value and the worker can be built eagerly. The
    /// localized error strings are resolved app-side (app bundle) and passed
    /// through. Read from the nonisolated socket-worker lane, so stored
    /// `nonisolated`.
    nonisolated(unsafe) var controlRemoteTmuxWorker = ControlRemoteTmuxWorker(
        reading: TerminalControllerRemoteTmuxReading(),
        strings: ControlRemoteTmuxStrings(
            disabled: String(
                localized: "socket.remoteTmux.disabled",
                defaultValue: "remote tmux beta is disabled"
            ),
            hostRequired: String(
                localized: "socket.remoteTmux.hostRequired",
                defaultValue: "host is required"
            ),
            sessionRequired: String(
                localized: "socket.remoteTmux.sessionRequired",
                defaultValue: "session is required"
            ),
            hostAndSessionRequired: String(
                localized: "socket.remoteTmux.hostAndSessionRequired",
                defaultValue: "host and session are required"
            )
        )
    )

    /// The worker-lane `workspace.remote.pty_*` RPC handler (CmuxControlSocket),
    /// reaching the live window/workspace/surface graph (`AppDelegate.shared`, each
    /// `Workspace`'s remote `RemoteSessionCoordinator` and moved-surface matching,
    /// the handle-ref vocabulary, and the availability `NSCondition`) strictly
    /// through the ``ControlRemotePTYReading`` seam conformed by
    /// ``TerminalControllerRemotePTYReading``. The conformer holds no live
    /// `TerminalController` state (it forwards to the `@MainActor`-coupled
    /// resolution methods on `TerminalController.shared`), so it is a plain
    /// `Sendable` value and the worker can be built eagerly. The five PTY command
    /// bodies + payload shaping + `remote_pty_error` rendering live in the package
    /// ``ControlRemotePTYWorker``. Built in `init` once `self` is available (the
    /// seam conformer holds `self` weakly). Read from the nonisolated socket-worker
    /// lane, so stored `nonisolated`.
    nonisolated(unsafe) var controlRemotePTYWorker: ControlRemotePTYWorker?

    /// The worker-lane `browser.find.*` RPC handler (CmuxControlSocket), reaching
    /// the live browser surface (panel resolution, finder-script construction, JS
    /// evaluation, element-ref allocation) strictly through the
    /// ``ControlBrowserQueryReading`` seam conformed over this controller. Built
    /// in `init` once `self` is available (the seam conformer holds `self`
    /// weakly). Read from the nonisolated socket-worker lane, so stored
    /// `nonisolated`.
    nonisolated(unsafe) var controlBrowserQueryWorker: ControlBrowserQueryWorker?

#if DEBUG
    /// The worker-lane `debug.sidebar.simulate_drag` RPC handler
    /// (CmuxControlSocket), reaching the live per-window `TabManager` + the
    /// `CmuxSidebar` `SidebarDragState` strictly through the
    /// ``ControlSidebarSimulateDragReading`` seam conformed over this controller.
    /// `#if DEBUG`-only (the command exists only in DEBUG builds). Built in `init`
    /// once `self` is available (the seam conformer holds `self` weakly). Read from
    /// the nonisolated socket-worker lane, so stored `nonisolated`.
    nonisolated(unsafe) var controlSidebarSimulateDragWorker: ControlSidebarSimulateDragWorker?
#endif

    /// The worker-lane handler for the v2 `browser.*` navigation commands
    /// (`browser.navigate` / `browser.back` / `browser.forward` /
    /// `browser.reload`). Lives in CmuxControlSocket's
    /// ``ControlBrowserNavigationWorker``, reaching the live browser surface
    /// (`TabManager` / `surface_id` / workspace / browser-panel resolution, the
    /// navigation calls, the ref computation, the post-action snapshot) strictly
    /// through the ``ControlBrowserNavigationReading`` seam conformed over this
    /// controller. Built in `init` once `self` is available (the seam conformer
    /// holds `self` weakly). Read from the nonisolated socket-worker lane, so
    /// stored `nonisolated`.
    nonisolated(unsafe) var controlBrowserNavigationWorker: ControlBrowserNavigationWorker?

    /// The worker-lane handler for the v2 `browser.*` interaction commands
    /// (`click`/`dblclick`/`hover`/`focus`/`type`/`fill`/`press`/`keydown`/`keyup`/
    /// `check`/`uncheck`/`select`/`scroll`/`scroll_into_view`/`highlight`). Lives in
    /// CmuxControlSocket's ``ControlBrowserInteractionWorker``, reaching the live
    /// browser surface strictly through the ``ControlBrowserInteractionReading``
    /// seam conformed over this controller. Built in `init` (the conformer holds
    /// `self` weakly). Read from the nonisolated socket-worker lane, so `nonisolated`.
    nonisolated(unsafe) var controlBrowserInteractionWorker: ControlBrowserInteractionWorker?

    /// The worker-lane handler for the feed/feedback commands (`feed.push`,
    /// `feed.permission.reply`, `feed.question.reply`, `feed.exit_plan.reply`,
    /// `feedback.submit`). Lives in CmuxControlSocket's ``ControlFeedWorker``,
    /// reaching the live feed plumbing (`CmuxEventBus`, `FeedCoordinator`,
    /// `FeedSocketEncoding`, the `WorkstreamEvent` decode, the iMessage-mode side
    /// effects, the feedback composer) strictly through the
    /// ``ControlFeedWorkerReading`` seam conformed over this controller. Built in
    /// `init` once `self` is available (the seam conformer holds `self` weakly).
    /// Read from the nonisolated socket-worker lane, so stored `nonisolated`.
    nonisolated(unsafe) var controlFeedWorker: ControlFeedWorker?

    private struct V2BrowserElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    private struct V2BrowserPendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    private final class V2BrowserUndefinedSentinel: Sendable {}

    private nonisolated static let v2BrowserEvalEnvelopeTypeKey = "__cmux_t"
    private nonisolated static let v2BrowserEvalEnvelopeValueKey = "__cmux_v"
    private nonisolated static let v2BrowserEvalEnvelopeTypeUndefined = "undefined"
    private nonisolated static let v2BrowserEvalEnvelopeTypeValue = "value"

    private var v2BrowserNextElementOrdinal: Int = 1
    private var v2BrowserElementRefs: [String: V2BrowserElementRefEntry] = [:]
    // `internal` (not `private`): the browser console/errors/state witnesses in
    // `TerminalController+ControlBrowserConsoleErrorsStateContext.swift` read and
    // mutate this per-surface frame-selector cache (state.save reads it,
    // state.load writes it), matching the cookies/storage cross-file witness
    // pattern. Still owned here because the worker-lane JS-eval methods read it
    // through `v2BrowserCurrentFrameSelector`.
    var v2BrowserFrameSelectorBySurface: [UUID: String] = [:]
    private var v2BrowserInitScriptsBySurface: [UUID: [String]] = [:]
    private var v2BrowserInitStylesBySurface: [UUID: [String]] = [:]
    private var v2BrowserDialogQueueBySurface: [UUID: [V2BrowserPendingDialog]] = [:]
    private var v2BrowserDownloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    private var v2BrowserUnsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]
    private nonisolated let v2BrowserUndefinedSentinel = V2BrowserUndefinedSentinel()
    /// Stateless browser-control logic (JS builders, value normalization,
    /// diagnostics, failure classification) extracted to `CmuxBrowser`.
    /// The per-surface mutable state and WebKit evaluation seam stay here.
    nonisolated let v2BrowserControl = BrowserControlService(
        evalEnvelope: BrowserEvalEnvelope(
            typeKey: TerminalController.v2BrowserEvalEnvelopeTypeKey,
            valueKey: TerminalController.v2BrowserEvalEnvelopeValueKey,
            typeUndefined: TerminalController.v2BrowserEvalEnvelopeTypeUndefined,
            typeValue: TerminalController.v2BrowserEvalEnvelopeTypeValue
        )
    )
    /// The bounded blocking-await primitive (CmuxControlSocket) every worker-lane
    /// browser JS-eval path blocks on. Stateless and `Sendable`, so a single
    /// shared instance serves every call; read from the nonisolated socket-worker
    /// lane via `v2AwaitCallback`.
    private nonisolated static let browserEvalAwaiter = ControlBrowserEvalAwaiter()

    private var browserDownloadObserver: NSObjectProtocol?

    func cleanupSurfaceState(surfaceIds: [UUID]) {
        for surfaceId in Set(surfaceIds) {
            v2BrowserFrameSelectorBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitScriptsBySurface.removeValue(forKey: surfaceId)
            v2BrowserInitStylesBySurface.removeValue(forKey: surfaceId)
            v2BrowserDialogQueueBySurface.removeValue(forKey: surfaceId)
            v2BrowserDownloadEventsBySurface.removeValue(forKey: surfaceId)
            v2BrowserUnsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)
            v2BrowserElementRefs = v2BrowserElementRefs.filter { $0.value.surfaceId != surfaceId }

            controlCommandCoordinator.removeRef(kind: .surface, uuid: surfaceId)
        }
    }

    /// Bridges the package server's event closures back to the controller.
    /// Assigned exactly once during `init`, before the listener can start, and
    /// read-only afterward; the controller is an app-lifetime singleton.
    private final class ServerEventTarget: @unchecked Sendable {
        weak var controller: TerminalController?
    }

    private init(
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        transport: SocketTransport = SocketTransport(),
        listenerPolicy: SocketListenerPolicy = SocketListenerPolicy(),
        remoteProxyBroker: any RemoteProxyBrokering = RemoteProxyBroker(
            tunnelProvider: RemoteDaemonProxyTunnelProvider(strings: .appLocalized, ptyBridgeStrings: AppRemotePTYBridgeStrings())
        )
    ) {
        self.passwordStore = passwordStore
        self.transport = transport
        self.remoteProxyBroker = remoteProxyBroker
        let serverEventTarget = ServerEventTarget()
        let socketServer = SocketControlServer(
            transport: transport,
            listenerPolicy: listenerPolicy,
            events: Self.makeSocketServerEvents(target: serverEventTarget)
        )
        self.socketServer = socketServer
        // Single consumer of the accepted-connection stream, detached so
        // accepts never funnel through the main actor. Each connection still
        // gets a dedicated thread: command bodies block (main-thread sync
        // hops, semaphore waits), so never the cooperative pool.
        self.socketConnectionsTask = Task.detached {
            for await connection in socketServer.connections {
                guard let controller = serverEventTarget.controller else {
                    close(connection.socket)
                    continue
                }
                controller.spawnClientHandler(socket: connection.socket, peerPid: connection.peerProcessID)
            }
        }
        serverEventTarget.controller = self
        controlCommandCoordinator.context = self
        controlAuthWorker = ControlAuthWorker(reading: TerminalControllerAuthReading(owner: self))
        controlBrowserQueryWorker = ControlBrowserQueryWorker(
            reading: TerminalControllerBrowserQueryReading(owner: self)
        )
        controlRemotePTYWorker = ControlRemotePTYWorker(
            reading: TerminalControllerRemotePTYReading(owner: self)
        )
        controlBrowserNavigationWorker = ControlBrowserNavigationWorker(
            reading: TerminalControllerBrowserNavigationReading(owner: self)
        )
        controlBrowserInteractionWorker = ControlBrowserInteractionWorker(
            reading: TerminalControllerBrowserInteractionReading(owner: self)
        )
        controlFeedWorker = ControlFeedWorker(
            reading: TerminalControllerFeedWorkerReading(owner: self)
        )
#if DEBUG
        controlSidebarSimulateDragWorker = ControlSidebarSimulateDragWorker(
            reading: TerminalControllerSidebarSimulateDragReading(owner: self)
        )
#endif
        browserDownloadObserver = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let surfaceId = note.userInfo?["surfaceId"] as? UUID,
                  let event = note.userInfo?["event"] as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var queue = self.v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                queue.append(event)
                self.v2BrowserDownloadEventsBySurface[surfaceId] = queue
            }
        }
    }
    nonisolated func currentSocketPathForRemoteRestore() -> String? {
        socketServer.currentSocketPathForRemoteRestore()
    }

    @discardableResult
    func reserveStartupSocketPath(_ path: String) -> String {
        socketServer.reserveStartupSocketPath(path)
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        socketServer.activeSocketPath(preferredPath: preferredPath)
    }

    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        !currentSocketCommandFocusAllowanceStack().isEmpty
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        currentSocketCommandFocusAllowanceStack().last ?? false
    }

    /// Relaxed to `internal` so the v1 `move_workspace_to_window` /
    /// `new_workspace` witnesses (in the workspace-context conformance file) can
    /// read the active socket command's focus-allowance, matching the legacy v1
    /// bodies exactly.
    func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool, params: [String: Any] = [:]) -> Bool {
        if isV2 {
            return focusIntentV2Methods.contains(commandKey)
                || explicitFocusParamAllowsFocus(commandKey: commandKey, params: params)
        }
        if commandKey == "right_sidebar" {
            return rightSidebarCommandAllowsInAppFocusMutations(args: params["args"] as? String ?? "")
        }
        return focusIntentV1Commands.contains(commandKey)
    }

    private nonisolated static func rightSidebarCommandAllowsInAppFocusMutations(args: String) -> Bool {
        let parsed = RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(args))
        guard case .success(let request) = parsed else { return false }
        switch request.command {
        case .toggle, .show, .focus:
            return true
        case .setMode(_, let focus):
            return focus
        case .hide, .getState:
            return false
        }
    }

    nonisolated func withSocketCommandPolicy<T>(commandKey: String, isV2: Bool, params: [String: Any] = [:], _ body: () -> T) -> T {
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(commandKey: commandKey, isV2: isV2, params: params)
        var stack = Self.currentSocketCommandFocusAllowanceStack()
        stack.append(allowsFocusMutation)
        Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        defer {
            var stack = Self.currentSocketCommandFocusAllowanceStack()
            if !stack.isEmpty {
                _ = stack.popLast()
            }
            Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        }
        return body()
    }

    private nonisolated static func currentSocketCommandFocusAllowanceStack() -> [Bool] {
        Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] as? [Bool] ?? []
    }

    private nonisolated static func setCurrentSocketCommandFocusAllowanceStack(_ stack: [Bool]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: socketCommandFocusAllowanceStackKey)
        } else {
            Thread.current.threadDictionary[socketCommandFocusAllowanceStackKey] = stack
        }
    }

    private nonisolated static func withSocketCommandPolicyStack<T>(_ stack: [Bool], _ body: () -> T) -> T {
        let previous = currentSocketCommandFocusAllowanceStack()
        setCurrentSocketCommandFocusAllowanceStack(stack)
        defer { setCurrentSocketCommandFocusAllowanceStack(previous) }
        return body()
    }

#if DEBUG
    static func debugSocketCommandPolicySnapshot(
        commandKey: String,
        isV2: Bool,
        params: [String: Any] = [:]
    ) -> (insideSuppressed: Bool, insideAllowsFocus: Bool, outsideSuppressed: Bool, outsideAllowsFocus: Bool) {
        var insideSuppressed = false
        var insideAllowsFocus = false
        _ = Self.shared.withSocketCommandPolicy(commandKey: commandKey, isV2: isV2, params: params) {
            insideSuppressed = Self.shouldSuppressSocketCommandActivation()
            insideAllowsFocus = Self.socketCommandAllowsInAppFocusMutations()
            return 0
        }
        return (
            insideSuppressed: insideSuppressed,
            insideAllowsFocus: insideAllowsFocus,
            outsideSuppressed: Self.shouldSuppressSocketCommandActivation(),
            outsideAllowsFocus: Self.socketCommandAllowsInAppFocusMutations()
        )
    }

    static func debugNotifyTargetQueuedResponseForTesting(_ args: String) -> String {
        Self.shared.notifyTargetQueued(args)
    }
#endif

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    nonisolated static func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    nonisolated static func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    nonisolated static func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    nonisolated static func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }

    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        // Ghostty's VT formatter writes row separators as CRLF. Swift treats
        // CRLF as one Character, so split(separator: "\n") would miss rows.
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated static func parseReportedShellActivityState(
        _ rawState: String
    ) -> PanelShellActivityState? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "prompt", "idle":
            return .promptIdle
        case "running", "busy", "command":
            return .commandRunning
        case "unknown", "clear":
            return .unknown
        default:
            return nil
        }
    }

    nonisolated static func parseRemotePortScanKickReason(
        _ rawReason: String
    ) -> PortScanKickReason? {
        switch rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "running", "foreground", "start":
            return .command
        case "refresh", "prompt", "idle":
            return .refresh
        default:
            return nil
        }
    }

    /// Update which window's TabManager receives socket commands.
    /// This is used when the user switches between multiple terminal windows.
    func setActiveTabManager(_ tabManager: TabManager?) {
        if let tabManager {
            AppDelegate.shared?.ensureMobileWorkspaceListObserver(for: tabManager)
        }
        self.tabManager = tabManager
    }

    func activeTabManagerForCallerNotification() -> TabManager? { tabManager }

    private nonisolated static func shouldCaptureSocketListenerFailure(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        let now = Date()
        socketListenerFailureCaptureLock.lock()
        defer { socketListenerFailureCaptureLock.unlock() }
        if let lastCapturedAt = socketListenerFailureLastCapturedAt[key],
           now.timeIntervalSince(lastCapturedAt) < socketListenerFailureCaptureCooldown {
            return false
        }
        socketListenerFailureLastCapturedAt[key] = now
        return true
    }

    /// Builds the package server's host-callback seam. `target` is filled in
    /// at the end of `init`; no listener event can fire before `start`.
    private nonisolated static func makeSocketServerEvents(
        target: ServerEventTarget
    ) -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, data in
                sentryBreadcrumb(message, category: "socket", data: data)
            },
            failure: { message, stage, errnoCode, data in
                sentryBreadcrumb(message, category: "socket", data: data)
                guard shouldCaptureSocketListenerFailure(
                    message: message,
                    stage: stage,
                    path: data["path"] as? String ?? "",
                    errnoCode: errnoCode
                ) else {
                    return
                }
                sentryCaptureError(message, category: "socket", data: data, contextKey: "socket_listener")
            },
            listenerDidStart: { path, _ in
                // @MainActor closure, invoked synchronously inside start().
                target.controller?.socketListenerDidStart(path: path)
            },
            recordLastSocketPath: { path in
                SocketControlSettings.recordLastSocketPath(path)
            },
            pathMissingDetected: { path, generation in
                Task { @MainActor in
                    target.controller?.restartSocketListenerIfPathMissing(path: path, generation: generation)
                }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                target.controller?.scheduleListenerRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
            }
        )
    }

    /// Inject the auth graph. Call once at the composition root, before the
    /// socket listener accepts auth commands.
    @MainActor
    func attachAuth(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.authCoordinator = coordinator
        self.browserSignInFlow = browserSignIn
    }


    func start(
        tabManager: TabManager,
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) {
        self.tabManager = tabManager
        socketServer.start(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
    }

    /// Invoked synchronously inside the server's `start()` on the main
    /// actor, at the exact lifecycle point the legacy implementation posted
    /// `.socketListenerDidStart`.
    private func socketListenerDidStart(path: String) {
        NotificationCenter.default.post(
            name: .socketListenerDidStart,
            object: self,
            userInfo: ["path": path]
        )

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            guard let self, let tabManager = self.tabManager else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            let validSurfaceIds = Set(workspace.panels.keys)
            guard validSurfaceIds.contains(panelId) else { return }
            workspace.surfaceListeningPorts[panelId] = ports.isEmpty ? nil : ports
            workspace.recomputeListeningPorts()
        }
        PortScanner.shared.onAgentPortsUpdated = { [weak self] workspaceId, ports in
            guard let self, let tabManager = self.tabManager else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            if workspace.agentListeningPorts != ports {
                workspace.agentListeningPorts = ports
                workspace.recomputeListeningPorts()
            }
        }
        PortScanner.shared.agentPIDsProvider = { [weak self] workspaceIds in
            guard let self, let tabManager = self.tabManager else { return [:] }
            var pidsByWorkspace: [UUID: Set<Int>] = [:]
            for workspaceId in workspaceIds {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
                let pids = Set(workspace.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                if !pids.isEmpty {
                    pidsByWorkspace[workspaceId] = pids
                }
            }
            return pidsByWorkspace
        }
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        socketServer.listenerHealth(expectedSocketPath: expectedSocketPath)
    }

    private func restartSocketListenerIfPathMissing(path: String, generation: UInt64) {
        guard let tabManager else { return }
        let restartMode = socketServer.accessMode
        guard socketServer.shouldRestartForMissingPath(path: path, generation: generation) else { return }

        sentryBreadcrumb(
            "socket.listener.restart",
            category: "socket",
            data: [
                "mode": restartMode.rawValue,
                "path": path,
                "source": "path_monitor",
                "generation": generation
            ]
        )
        stop()
        start(tabManager: tabManager, socketPath: path, accessMode: restartMode)
    }

    func stop() {
        // Synchronous by contract: termination needs the unlink before exit.
        socketServer.stop()
    }

    private nonisolated func writeSocketResponse(_ response: String, to socket: Int32) -> Bool {
        let payload = response + "\n"
        return transport.writeAll(Data(payload.utf8), to: socket)
    }

    private nonisolated func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private nonisolated func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private nonisolated func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private nonisolated func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard socketServer.accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    /// Interim bridged view of a decoded `ControlRequest` with Foundation
    /// (`Any`) field shapes, so the existing command bodies keep their
    /// `[String: Any]` params until they migrate onto the typed DTOs in the
    /// ControlCommandCoordinator stage.
    private struct V2SocketRequest {
        let id: Any?
        let method: String
        let params: [String: Any]
        /// The typed request envelope this bridges from. Retained so worker-lane
        /// handlers moved into CmuxControlSocket (e.g. `ControlAuthWorker`) can
        /// read typed `JSONValue` params without a Foundation round-trip.
        let control: ControlRequest

        init(bridging request: ControlRequest) {
            id = request.id.map(\.foundationObject)
            method = request.method
            params = request.params.mapValues { $0.foundationObject }
            control = request
        }
    }

    /// Wire-protocol helpers (parse/encode) shared with the package;
    /// stateless, so single instances serve every thread.
    private nonisolated static let v2Parser = ControlRequestParser()
    // `internal` (not `private`): the worker-lane auth conformance lives in a
    // separate extension file (`TerminalController+AuthStatusReading.swift`),
    // which cannot reach a `private` member.
    nonisolated static let v2Encoder = ControlResponseEncoder()
    // `internal` (not `private`): the notification-domain conformance and the
    // V1 send/notify conformance live in separate extension files
    // (`TerminalController+ControlNotificationContext.swift`,
    // `TerminalController+ControlSurfaceSendNotifyV1.swift`) and forward their
    // notification field shaping through this single source of truth.
    nonisolated static let notificationFieldFormatter = ControlNotificationFieldFormatter()

    private nonisolated static func executionPolicy(forV2Method method: String) -> ControlCommandExecutionPolicy {
        ControlCommandExecutionPolicy(forMethod: method)
    }

    private nonisolated func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        guard let request = Self.v2Parser.lenientRequest(fromLine: command) else {
            return nil
        }
        return V2SocketRequest(bridging: request)
    }

    private nonisolated func socketWorkerV2ResponseIfHandled(for command: String) -> (handled: Bool, response: String?) {
        guard let request = parseV2SocketRequest(command),
              Self.executionPolicy(forV2Method: request.method).runsOnSocketWorker else {
            return (false, nil)
        }

        return withSocketCommandPolicy(commandKey: request.method, isV2: true, params: request.params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: request.method, params: request.params) {
                return (true, v2Result(id: request.id, workspaceParamError))
            }
            if request.method == "feed.push", request.id == nil {
                guard let waitTimeout = FeedPushWaitTimeout(rawValue: request.params["wait_timeout_seconds"])?.seconds else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push wait_timeout_seconds must be numeric and between 0 and 120"
                    ))
                }
                guard waitTimeout == 0 else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push without an id requires wait_timeout_seconds 0"
                    ))
                }
                _ = socketWorkerV2Response(request)
                return (true, nil)
            }
            return (true, socketWorkerV2Response(request))
        }
    }

    private nonisolated func socketWorkerV2Response(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.status", "auth.sign_in_url", "auth.begin_sign_in", "auth.sign_out":
            // The `auth.*` command bodies live in CmuxControlSocket's
            // `ControlAuthWorker`, reading live auth state through the
            // `AuthStatusReading` seam (conformed by `TerminalControllerAuthReading`
            // over `authCoordinator` / `browserSignInFlow`). The worker is `async`
            // (it replaced the per-command `DispatchSemaphore` + `Task { @MainActor }`
            // / `v2MainSync` bridges with the seam's async surface). This single
            // semaphore is the one remaining worker-thread→async bridge: the
            // worker lane is a synchronous `nonisolated` contract, so we block it
            // here exactly as the legacy bodies blocked on their per-command
            // semaphores. The decoded typed request is reused so the worker reads
            // typed `JSONValue` params (no Foundation round-trip).
            return runAuthWorker(request.control)
        case "feedback.submit", "feed.push", "feed.permission.reply",
             "feed.question.reply", "feed.exit_plan.reply":
            // The feed/feedback worker-lane command bodies live in
            // CmuxControlSocket's ``ControlFeedWorker``, reaching the live feed
            // plumbing (`CmuxEventBus`, `FeedCoordinator`, `FeedSocketEncoding`,
            // the `WorkstreamEvent` decode, the iMessage-mode side effects, the
            // feedback composer) strictly through the ``ControlFeedWorkerReading``
            // seam (conformed by `TerminalControllerFeedWorkerReading` over this
            // controller). The worker is synchronous and blocks the worker thread
            // exactly as the legacy `nonisolated` `v2FeedPush` / `v2FeedbackSubmit`
            // bodies did (`FeedCoordinator.ingestBlocking`, the feedback
            // semaphore), so no worker-thread→async bridge is needed.
            return runFeedWorker(request.control)
        case "browser.download.wait":
            return v2Result(id: request.id, v2BrowserDownloadWaitOnSocketWorker(params: request.params))
        case "browser.find.role", "browser.find.text", "browser.find.label",
             "browser.find.placeholder", "browser.find.alt", "browser.find.title",
             "browser.find.testid", "browser.find.first", "browser.find.last", "browser.find.nth":
            // The `browser.find.*` semantic-element locators are owned by
            // CmuxControlSocket's ``ControlBrowserQueryWorker``, reaching the live
            // browser surface through the ``ControlBrowserQueryReading`` seam
            // (`controlResolveBrowserFind`). Keep ref payloads fresh first, like
            // the legacy shared dispatch did for every JS-eval browser method.
            v2MainSync { self.v2RefreshKnownRefs() }
            return runBrowserQueryWorker(request.control)
        case "browser.navigate", "browser.back", "browser.forward", "browser.reload":
            // Owned by CmuxControlSocket's ``ControlBrowserNavigationWorker`` via
            // the ``ControlBrowserNavigationReading`` seam. Refresh refs first like
            // the legacy shared dispatch did for every JS-eval browser method.
            v2MainSync { self.v2RefreshKnownRefs() }
            return runBrowserNavigationWorker(request.control)
        case "browser.click", "browser.dblclick", "browser.hover", "browser.focus",
             "browser.type", "browser.fill", "browser.press", "browser.keydown", "browser.keyup",
             "browser.check", "browser.uncheck", "browser.select", "browser.scroll",
             "browser.scroll_into_view", "browser.highlight":
            // The `browser.*` interaction commands are owned by CmuxControlSocket's
            // ``ControlBrowserInteractionWorker``, reaching the live browser surface
            // through the ``ControlBrowserInteractionReading`` seam
            // (`controlResolveBrowserInteraction`). Refresh refs first like the
            // legacy shared dispatch did for every JS-eval browser method.
            v2MainSync { self.v2RefreshKnownRefs() }
            return runBrowserInteractionWorker(request.control)
        case "browser.get.text", "browser.get.html", "browser.get.value", "browser.get.attr",
             "browser.get.count", "browser.get.box", "browser.get.styles",
             "browser.is.visible", "browser.is.enabled", "browser.is.checked":
            // The read-only `browser.get.*` / `browser.is.*` getters are owned by
            // CmuxControlSocket's ``ControlBrowserQueryWorker`` (alongside
            // `browser.find.*`), reaching the live browser surface through the
            // ``ControlBrowserQueryReading`` seam (`controlResolveBrowserQuery`).
            // Refresh refs first like the legacy shared dispatch did for every
            // JS-eval browser method.
            v2MainSync { self.v2RefreshKnownRefs() }
            return runBrowserQueryWorker(request.control)
        case "browser.snapshot", "browser.eval", "browser.wait":
            // Keep ref payloads fresh like the main-actor dispatch path does.
            v2MainSync { self.v2RefreshKnownRefs() }
            return v2Result(id: request.id, v2BrowserJSCommandOnSocketWorker(method: request.method, params: request.params))
        case "browser.profiles.list":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.list(params: request.params)
            }
        case "browser.profiles.create":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.create(params: request.params)
            }
        case "browser.profiles.rename":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.rename(params: request.params)
            }
        case "browser.profiles.clear":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.clear(params: request.params)
            }
        case "browser.profiles.delete":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.delete(params: request.params)
            }
        case "browser.import.cookies":
            return v2VmCall(id: request.id, timeoutSeconds: 10 * 60) {
                let outcome = try await BrowserImportAutomation.importCookies(params: request.params)
                return outcome.socketPayload
            }
        case "mobile.attach_ticket.create":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2MobileAttachTicketCreate(params: request.params)
            }
        case "system.ping", "system.capabilities":
            // The two `mainThreadCallable` probes; bodies live in CmuxControlSocket's
            // ``ControlSystemProbe`` (shared with the coordinator). Built here with
            // no main hop, exactly as the legacy inline bodies did.
            return Self.v2Encoder.response(id: request.control.id, systemProbeResponse(request.method))
        case "system.top":
            return v2Result(id: request.id, v2SystemTop(params: request.params))
        case "system.memory":
            return v2Result(id: request.id, v2SystemMemory(params: request.params))
        case "workspace.env":
            // Worker-lane method owned by ControlCommandCoordinator
            // (`workspaceEnv`, reached via `handle`). Its body is entirely a
            // `v2MainSync` block (resolve workspace + copy its env dict), so the
            // worker thread hops to the main actor here exactly as the legacy
            // `v2WorkspaceEnv` did; the per-key explicit-target validation lives
            // in the coordinator. `handle` returns non-nil for this owned method,
            // so the encode-failure fallback is unreachable for `workspace.env`.
            return v2MainSync {
                guard let result = self.controlCommandCoordinator.handle(request.control) else {
                    return ControlResponseEncoder.encodeFailureResponse
                }
                return Self.v2Encoder.response(id: request.control.id, result)
            }
        case "workspace.remote.pty_sessions", "workspace.remote.pty_close",
             "workspace.remote.pty_detach", "workspace.remote.pty_bridge",
             "workspace.remote.pty_resize":
            // The `workspace.remote.pty_*` command bodies live in
            // CmuxControlSocket's ``ControlRemotePTYWorker`` (param validation,
            // the per-command controller calls, the reply payload shaping, and the
            // `remote_pty_error` rendering). They reach the live
            // window/workspace/surface graph + each workspace's persistent-PTY
            // controller strictly through the ``ControlRemotePTYReading`` /
            // ``ControlRemotePTYControlling`` seams conformed by
            // ``TerminalControllerRemotePTYReading`` /
            // ``RemoteSessionCoordinatorPTYControlling``. The worker is
            // synchronous (its controller calls block the worker thread on the
            // controller queue, exactly as the legacy bodies did), so
            // ``runRemotePTYWorker`` is a direct call, not an async bridge.
            return runRemotePTYWorker(request.control)
        case "remote.tmux.sessions", "remote.tmux.attach", "remote.tmux.detach",
             "remote.tmux.state", "remote.tmux.mirror", "remote.tmux.window":
            // The `remote.tmux.*` command bodies live in CmuxControlSocket's
            // ``ControlRemoteTmuxWorker`` (the beta-flag gate, the
            // SSH-injection-hardened param parsing, the per-command timeout +
            // `vm_error` rendering, and the reply payload shaping), reaching the
            // live `@MainActor` `RemoteTmuxController` strictly through the
            // ``ControlRemoteTmuxReading`` seam conformed by
            // ``TerminalControllerRemoteTmuxReading``. The worker is `async`; the
            // single worker-thread→async bridge lives in ``runRemoteTmuxWorker``
            // (replacing the per-body `v2VmCall` semaphore + `MainActor.run`).
            return runRemoteTmuxWorker(request.control)
        case "sidebar.custom.validate", "sidebar.custom.reload", "sidebar.custom.select":
            // Worker-lane bodies live in CmuxControlSocket's
            // ``ControlSidebarCustomWorker`` (validation runs on this worker
            // thread; reload/select side effects hop to main inside the seam).
            return runSidebarCustomWorker(request.control)
#if DEBUG
        case "debug.sidebar.simulate_drag":
            // Worker-lane body lives in CmuxControlSocket's
            // ``ControlSidebarSimulateDragWorker`` (the off-main resampling +
            // inter-tick Thread.sleep loop + reply payload); param resolution and
            // the SidebarDragState mutations hop to main inside the
            // ``ControlSidebarSimulateDragReading`` seam.
            return runSidebarSimulateDragWorker(request.control)
#endif
        case let method where method.hasPrefix("vm."):
            return socketWorkerCloudVMResponse(method: method, id: request.id, params: request.params)
        case let method where method.hasPrefix("remotes."):
            return socketWorkerRemotesResponse(method: method, id: request.id, params: request.params)
        default:
            return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated func spawnClientHandler(socket clientSocket: Int32, peerPid: pid_t?) {
        Thread.detachNewThread { [weak self] in
            guard let self else {
                close(clientSocket)
                return
            }
            self.handleClient(clientSocket, peerPid: peerPid)
        }
    }

    private nonisolated func scheduleListenerRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded rearm delay on the server's injected recovery clock
            // (replaces the legacy main-queue asyncAfter); a stale fire is a
            // no-op via the pending-rearm generation guard in the claim.
            try? await self.socketServer.recoveryClock.sleep(forMilliseconds: delayMs)
            guard let tabManager = self.tabManager else { return }
            guard let restartPath = self.socketServer.claimPendingRearm(
                generation: generation,
                errnoCode: errnoCode,
                consecutiveFailures: consecutiveFailures,
                delayMs: delayMs
            ) else { return }

            let restartMode = self.socketServer.accessMode

            self.stop()
            self.start(
                tabManager: tabManager,
                socketPath: restartPath,
                accessMode: restartMode,
                preserveAcceptFailureStreak: true
            )
        }
    }

    private nonisolated func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // In allowAll mode (env-var only), skip the ancestry check.
        if socketServer.accessMode == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? transport.peerProcessID(of: socket)
            if let pid {
                guard transport.isProcessDescendant(pid, of: getpid()) else {
                    _ = writeSocketResponse(
                        "ERROR: Access denied — only processes started inside cmux can connect",
                        to: socket
                    )
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard transport.peerHasSameUID(socket) else {
                    _ = writeSocketResponse(
                        "ERROR: Unable to verify client process",
                        to: socket
                    )
                    return
                }
            }
        }

        var authenticated = false
        let lineReader = ControlClientLineReader(socket: socket)

        while let line = lineReader.nextLine(shouldContinueReading: { socketServer.isRunning }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var shouldCloseSocket = false
            autoreleasepool {
                if isEventsStreamRequest(trimmed) {
                    if let response = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                        if !writeSocketResponse(response, to: socket) {
                            shouldCloseSocket = true
                        }
                        return
                    }
                    handleEventsStreamRequest(trimmed, socket: socket)
                    shouldCloseSocket = true
                    return
                }

                let result = processSocketLine(trimmed, authenticated: authenticated)
                authenticated = result.authenticated
                if let response = result.response {
                    let didWriteResponse = writeSocketResponse(response, to: socket)
                    publishSocketEvents(command: trimmed, response: response)
                    if !didWriteResponse {
                        shouldCloseSocket = true
                    }
                }
            }
            if shouldCloseSocket {
                return
            }
        }
    }

    private nonisolated func processSocketLine(
        _ command: String,
        authenticated: Bool
    ) -> SocketLineProcessingResult {
#if DEBUG
        let debugInfo = Self.socketCommandDebugInfo(command)
        let debugStart = DispatchTime.now().uptimeNanoseconds
        let debugLoggingEnabled = Self.socketCommandDebugLoggingEnabled()
        if debugLoggingEnabled {
            Self.debugLogSocketCommand(
                "socket.command.begin proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey)"
            )
        }
#endif
        var nextAuthenticated = authenticated
        if let response = authResponseIfNeeded(for: command, authenticated: &nextAuthenticated) {
#if DEBUG
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
#endif
            return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
        }

        let response = processCommandUsingSocketExecutionPolicy(command)
#if DEBUG
        if let response {
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
        }
#endif
        return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
    }

#if DEBUG
    private struct SocketCommandDebugInfo {
        let protocolName: String
        let commandKey: String
    }

    private nonisolated static func socketCommandDebugLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[socketCommandDebugLogEnvironmentKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private nonisolated static func socketCommandDebugInfo(_ command: String) -> SocketCommandDebugInfo {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let method = dict["method"] as? String else {
            let commandKey = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "<empty>"
            return SocketCommandDebugInfo(protocolName: "v1", commandKey: sanitizedSocketDebugToken(commandKey))
        }
        return SocketCommandDebugInfo(protocolName: "v2", commandKey: sanitizedSocketDebugToken(method))
    }

    private nonisolated static func sanitizedSocketDebugToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "<empty>" : String(sanitized)
    }

    private nonisolated static func socketCommandDebugStatus(response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ERROR:") {
            return "error"
        }
        if trimmed.hasPrefix("{") {
            let prefix = trimmed.prefix(4096)
            if topLevelJSONResponseStatus(in: prefix) == "error" {
                return "error"
            }
        }
        return "ok"
    }

    private nonisolated static func topLevelJSONResponseStatus(in text: Substring) -> String? {
        var index = text.startIndex
        skipJSONWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)

        while index < text.endIndex {
            skipJSONWhitespace(in: text, index: &index)
            if index >= text.endIndex { return nil }
            if text[index] == "}" { return nil }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"",
                  let key = scanJSONString(in: text, index: &index) else {
                return nil
            }
            skipJSONWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skipJSONWhitespace(in: text, index: &index)

            if key == "error" {
                return "error"
            }
            if key == "ok" {
                if text[index...].hasPrefix("false") {
                    return "error"
                }
                if text[index...].hasPrefix("true") {
                    return "ok"
                }
            }
            guard skipJSONValue(in: text, index: &index) else {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func scanJSONString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var result = ""
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isEscaped {
                result.append(char)
                isEscaped = false
                continue
            }
            if char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                return result
            }
            result.append(char)
        }
        return nil
    }

    private nonisolated static func skipJSONValue(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        switch text[index] {
        case "\"":
            return scanJSONString(in: text, index: &index) != nil
        case "{", "[":
            return skipJSONContainer(in: text, index: &index)
        default:
            while index < text.endIndex {
                switch text[index] {
                case ",", "}":
                    return true
                default:
                    index = text.index(after: index)
                }
            }
            return true
        }
    }

    private nonisolated static func skipJSONContainer(in text: Substring, index: inout String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let opener = text[index]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 1
        index = text.index(after: index)
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    isInString = false
                }
                continue
            }
            if char == "\"" {
                isInString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func skipJSONWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex {
            switch text[index] {
            case " ", "\t", "\n", "\r":
                index = text.index(after: index)
            default:
                return
            }
        }
    }

    private nonisolated static func debugLogSocketCommandEndIfNeeded(
        debugInfo: SocketCommandDebugInfo,
        startedAt: UInt64,
        response: String,
        loggingEnabled: Bool
    ) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let status = socketCommandDebugStatus(response: response)
        guard loggingEnabled || elapsedMs >= socketCommandSlowThresholdMs || status != "ok" else {
            return
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        debugLogSocketCommand(
            "socket.command.end proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey) status=\(status) ms=\(elapsedText) bytes=\(response.utf8.count)"
        )
    }

    private nonisolated static func debugLogSocketCommand(_ message: @autoclosure () -> String) {
        cmuxDebugLog(message())
    }
#endif

    private nonisolated func processCommandUsingSocketExecutionPolicy(_ command: String) -> String? {
        if Thread.isMainThread,
           let request = parseV2SocketRequest(command),
           Self.executionPolicy(forV2Method: request.method) == .socketWorker(mainThreadCallable: false) {
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: "\(request.method) must run off the main thread"
            )
        }

        let socketWorkerResult = socketWorkerV2ResponseIfHandled(for: command)
        if socketWorkerResult.handled {
            guard let response = socketWorkerResult.response else {
                return nil
            }
            return response
        }

        if command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ping" {
            return withSocketCommandPolicy(commandKey: "ping", isV2: false) {
                "PONG"
            }
        }

        return v2MainSync {
            self.processCommand(command)
        }
    }

    /// Public entry point mirroring the socket's `processCommand` path so
    /// in-process callers (e.g. the Feed coordinator's `feed.jump` focus
    /// request) can reuse the full V1/V2 dispatcher without duplicating
    /// its auth/policy wrappers.
    nonisolated func handleSocketLine(_ line: String) -> String {
        return processCommandUsingSocketExecutionPolicy(line) ?? ""
    }

    private func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        let policyParams = cmd == "right_sidebar" ? ["args": args] : [:]
        return withSocketCommandPolicy(commandKey: cmd, isV2: false, params: policyParams) {
            // V1 domains migrated into CmuxControlSocket's ControlCommandCoordinator
            // (the sidebar metadata/pane/surface commands and the browser panel
            // commands) answer here; everything else falls through to the legacy
            // switch below.
            if let coordinatorV1 = controlCommandCoordinator.handleWindowV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleWorkspaceV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleSidebarV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleBrowserPanelV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleSurfaceSendNotifyV1(command: cmd, args: args)
                ?? controlCommandCoordinator.handleDebugV1(command: cmd, args: args) {
                return coordinatorV1
            }
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        // The v1 window commands (list_windows/current_window/focus_window/
        // new_window/close_window/move_workspace_to_window) and the v1 workspace
        // commands (list_workspaces/new_workspace/new_split/close_workspace/
        // select_workspace/current_workspace) are handled above by
        // ControlCommandCoordinator.handleWindowV1 / handleWorkspaceV1, whose
        // witnesses carry the app-coupled bodies (list_windows renders in the
        // coordinator from the shared window summaries).

        // The v1 surface listing/focus (list_surfaces/focus_surface), the
        // terminal-input commands (send/send_key/send_surface/send_key_surface,
        // plus DEBUG send_workspace), the notification commands (notify/
        // notify_surface/notify_target/notify_target_async/list_notifications/
        // clear_notifications), the app-focus commands (set_app_focus/
        // simulate_app_active), read_screen, and help are handled above by
        // ControlCommandCoordinator.handleSurfaceSendNotifyV1, whose witnesses
        // carry the app-coupled bodies.

        // Sidebar metadata/reporting commands (set_status/report_meta/
        // report_meta_block/clear_status/clear_meta/clear_meta_block/list_status/
        // list_meta/list_meta_blocks/set_agent_pid/set_agent_lifecycle/
        // agent_hibernation/clear_agent_pid/log/clear_log/list_log/set_progress/
        // clear_progress/report_git_branch/clear_git_branch/report_pr/report_review/
        // clear_pr/report_ports/clear_ports/report_tty/ports_kick/report_shell_state/
        // report_pr_action/report_pwd/sidebar_state/reset_sidebar/right_sidebar)
        // handled by ControlCommandCoordinator.

        // The v1-only DEBUG synthetic-input / drag-overlay probes
        // (simulate_type/simulate_file_drop/seed_drag_pasteboard_*/
        // clear_drag_pasteboard/drop_hit_test/drag_hit_chain/overlay_hit_gate/
        // overlay_drop_gate/portal_hit_gate/sidebar_overlay_gate/
        // terminal_drop_overlay_probe) are handled above by
        // ControlCommandCoordinator.handleDebugV1, whose witnesses carry the
        // app-coupled bodies.

        // Browser panel commands (open_browser/navigate/browser_back/browser_forward/
        // browser_reload/get_url/focus_webview/is_webview_focused) and the bonsplit
        // pane/surface commands (list_panes/list_pane_surfaces/focus_pane/
        // focus_surface_by_panel/drag_surface_to_split/new_pane/new_surface/
        // close_surface/reload_config/refresh_surfaces/surface_health) handled by
        // ControlCommandCoordinator (drag_surface_to_split forwards to the
        // still-shared v2SurfaceSplitOff).

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    // MARK: - V2 JSON Socket Protocol

    /// Runs a v2 command line (`{"method","params","id"}`) through the
    /// dispatcher in-process and returns the JSON response. Internal seam so
    /// in-app callers (e.g. custom-sidebar button actions) can drive the same
    /// command surface as the socket without reaching the private dispatcher.
    func runV2CommandLine(_ jsonLine: String) -> String {
        processV2Command(jsonLine)
    }

    private func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        let request: ControlRequest
        switch Self.v2Parser.request(fromLine: jsonLine) {
        case .failure(let parseError):
            return Self.v2Encoder.response(for: parseError)
        case .success(let parsed):
            request = parsed
        }

        let bridged = V2SocketRequest(bridging: request)
        let id: Any? = bridged.id
        let method = bridged.method
        let params = bridged.params

        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        return withSocketCommandPolicy(commandKey: method, isV2: true, params: params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: method, params: params) {
                return v2Result(id: id, workspaceParamError)
            }

            v2MainSync { self.v2RefreshKnownRefs() }

            // Domains migrated into CmuxControlSocket's ControlCommandCoordinator
            // (window so far) answer here, on the main actor, and encode through
            // the same encoder/id; everything else falls through to the legacy
            // switch below. processV2Command already runs on main, so the
            // coordinator's bodies need no per-read v2MainSync hop.
            if let coordinatorResult = controlCommandCoordinator.handle(request) {
                return Self.v2Encoder.response(id: request.id, coordinatorResult)
            }

            switch method {
        // system.ping / system.capabilities are handled above by
        // ControlCommandCoordinator (handleSystem via ControlSystemProbe); the
        // worker lane builds the same probe responses directly.
        // mobile.host.status/mobile.workspace.list/mobile.terminal.* (+terminal.*
        // aliases), mobile.terminal.paste/terminal.paste, and chat.sessions.dump
        // handled by ControlCommandCoordinator (bodies stay; shared with
        // mobileHostHandleRPC).

        // system.identify (forwards to the still-shared v2Identify), system.tree,
        // auth.login, and the DEBUG-only mobile.dev_stack_auth.configure handled
        // by ControlCommandCoordinator.

        // Windows (`window.*`) are handled above by ControlCommandCoordinator.

        // Workspaces
        // workspace.* (list/create/select/current/close/move_to_window/reorder[_many]/
        // prompt_submit/rename) + workspace.group.* handled by ControlCommandCoordinator.
        // workspace.action (forwards to the still-shared v2WorkspaceAction) and
        // extension.sidebar.snapshot handled by ControlCommandCoordinator.
        // workspace.next/previous/last/equalize_splits/set_auto_title + workspace.remote.*
        // (configure/foreground_auth_ready/reconnect/disconnect/status/pty_attach_end/
        // terminal_session_end) handled by ControlCommandCoordinator. The worker-lane
        // workspace.env method hops to the coordinator's workspaceEnv. The worker-lane
        // workspace.remote.pty_* methods (sessions/close/detach/bridge/resize) run in
        // CmuxControlSocket's ControlRemotePTYWorker via runRemotePTYWorker, reaching the
        // live graph + controller through the ControlRemotePTYReading/Controlling seams.

        // Settings/session/feedback: session.restore_previous, settings.open, and
        // feedback.open handled by ControlCommandCoordinator.

        // Feed (workstream): feed.jump/feed.list handled by ControlCommandCoordinator.


        // Surfaces / input: surface.list/current/focus/split/respawn/create/close/move/
        // reorder handled by ControlCommandCoordinator (surface.move forwards to the
        // still-shared v2SurfaceMove). surface.action/tab.action and
        // surface.drag_to_split/surface.split_off (the latter forwarding to the
        // still-shared v2SurfaceSplitOff) handled by ControlCommandCoordinator too.
        // surface.refresh/health/resume.set/get/clear, debug.terminals (forwards to the
        // still-shared v2DebugTerminals), surface.send_text/send_key/report_tty/
        // report_shell_state/ports_kick/clear_history/trigger_flash, and surface.read_text
        // handled by ControlCommandCoordinator.

        // Panes
        // pane.* handled by ControlCommandCoordinator.

        // Notifications: all notification.* methods (including create_for_caller,
        // whose body stays in TerminalNotificationCallerResolver behind the
        // ControlNotificationContext seam) handled by ControlCommandCoordinator.

        // App focus (app.focus_override.set/app.simulate_active) handled by ControlCommandCoordinator.

        // Browser
        // The non-JS-evaluating, main-actor browser.* methods (browser.open_split,
        // browser.react_grab.toggle, browser.devtools.toggle, browser.console.show,
        // browser.focus_mode.set, browser.zoom.set, browser.history.clear,
        // browser.url.get, browser.focus_webview, browser.is_webview_focused,
        // browser.addinitscript, browser.addscript, browser.addstyle,
        // browser.dialog.accept, browser.dialog.dismiss, browser.import.dialog) are
        // handled above by ControlCommandCoordinator (handleBrowser) via the
        // ControlBrowserContext seam.
        // The read-only browser getters (browser.get.title, browser.frame.select,
        // browser.frame.main, browser.screenshot) are handled above by
        // ControlCommandCoordinator (handleBrowserReadOnly) via the same seam.
        // browser methods that evaluate page JavaScript run on the socket worker
        // (see ControlCommandExecutionPolicy.socketWorkerMethods); they never reach
        // this switch. find/navigation/interaction are owned by CmuxControlSocket's
        // ControlBrowser{Query,Navigation,Interaction}Worker; snapshot/eval/wait/
        // get/is stay on v2BrowserJSCommandOnSocketWorker.
        // browser.dialog.accept/dismiss, browser.import.dialog,
        // browser.cookies.get/set/clear, browser.storage.get/set/clear, and
        // browser.addinitscript/addscript/addstyle handled above by
        // ControlCommandCoordinator (handleBrowser) via the ControlBrowserContext
        // seam.
        // browser.tab.new / browser.tab.list / browser.tab.switch /
        // browser.tab.close handled above by ControlCommandCoordinator
        // (handleBrowserTabs) via the ControlBrowserContext seam.
        // browser.console.list / browser.console.clear / browser.errors.list /
        // browser.state.save / browser.state.load handled above by
        // ControlCommandCoordinator (handleBrowserConsoleErrorsState) via the
        // ControlBrowserContext seam.
        // browser.viewport.set / browser.geolocation.set / browser.offline.set /
        // browser.trace.start / browser.trace.stop / browser.screencast.start /
        // browser.screencast.stop / browser.input_mouse / browser.input_keyboard
        // / browser.input_touch (the deliberately-unsupported stubs) and
        // browser.network.route / browser.network.unroute / browser.network.requests
        // (the unsupported-attempt log) are handled above by
        // ControlCommandCoordinator (handleBrowserUnsupported).

        // Markdown/files/projects: markdown.open, file.open (forwards to the
        // still-shared v2FileOpen), and project.* handled by ControlCommandCoordinator.

        // surface.read_text handled by ControlCommandCoordinator.


        // Debug / test-only: the DEBUG-gated debug.* domain (shortcuts, typing,
        // textbox fixtures, command palette, browser probes, sidebar/terminal
        // focus, file drop, layout/portal/flash/panel-snapshot counters, window
        // screenshot, and the session-snapshot benchmark/seed methods) handled
        // by ControlCommandCoordinator. debug.sidebar.simulate_drag is dispatched
        // on the socket worker (see ControlCommandExecutionPolicy + the worker
        // switch in processCommand) so its inter-tick Thread.sleep never blocks
        // the main actor.

            default:
                return v2Error(id: id, code: "method_not_found", message: "Unknown method")
            }
        }
    }

    /// Builds the `system.ping` / `system.capabilities` worker-lane result via
    /// CmuxControlSocket's ``ControlSystemProbe`` (shared with the coordinator).
    /// The probe owns the catalog/DEBUG-split/sorted-emit contract; this seam
    /// supplies only the live `socket_path` / `access_mode` (nonisolated reads).
    /// `method` is always one of the two probe verbs, so the `default` ping arm
    /// is the byte-faithful fall-through for `system.ping`.
    private nonisolated func systemProbeResponse(_ method: String) -> ControlCallResult {
        let probe = ControlSystemProbe()
        switch method {
        case "system.capabilities":
            return probe.capabilities(
                socketPath: socketServer.currentSocketPath,
                accessModeRawValue: socketServer.accessMode.rawValue
            )
        default:
            return probe.ping()
        }
    }

    func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketServer.currentSocketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let paneUUID = ws.bonsplitController.focusedPaneId?.id
                let surfaceUUID = ws.focusedPanelId
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue }),
                    "is_browser_surface": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
                    var payload: [String: Any] = [
                        "window_id": v2OrNull(callerWindowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                        "workspace_id": wsId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
                    ]

                    if let surfaceId, ws.panels[surfaceId] != nil {
                        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
                        payload["surface_id"] = surfaceId.uuidString
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        payload["tab_id"] = surfaceId.uuidString
                        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
                        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
                        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
                        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
                        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
                    } else {
                        payload["surface_id"] = NSNull()
                        payload["surface_ref"] = NSNull()
                        payload["tab_id"] = NSNull()
                        payload["tab_ref"] = NSNull()
                        payload["surface_type"] = NSNull()
                        payload["is_browser_surface"] = NSNull()
                        payload["pane_id"] = NSNull()
                        payload["pane_ref"] = NSNull()
                    }
                    resolvedCaller = payload
                }
            }
        }

        var result: [String: Any] = [
            "socket_path": socketServer.currentSocketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            result["bundle_identifier"] = bundleIdentifier
        }
        result["app_bundle_path"] = Bundle.main.bundleURL.path
        if let executablePath = Bundle.main.executableURL?.path {
            result["app_executable_path"] = executablePath
        }
        if let cliPath = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
            .path {
            result["app_cli_path"] = cliPath
        }
        return result
    }

    private struct V2WindowRouting {
        let includeAllWindows: Bool
        let requestedWindowId: UUID?
        let focused: [String: Any]
        let caller: [String: Any]
        let focusedWindowId: UUID?
    }

    private func v2WindowSelectorDetails(params: [String: Any]) -> [String: Any]? {
        guard let rawWindowId = params["window_id"] else { return nil }
        if let string = rawWindowId as? String {
            return ["window_id": string]
        }
        return ["window_id": String(describing: rawWindowId)]
    }

    private func parseV2WindowRouting(params: [String: Any]) -> (routing: V2WindowRouting?, error: V2CallResult?) {
        if params["all_windows"] != nil, v2Bool(params, "all_windows") == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid all_windows. Pass true or false, or omit it. Use --window <id|ref|index> to target one window or --all-windows to target all windows.",
                    data: nil
                )
            )
        }

        let includeAllWindows = v2Bool(params, "all_windows") ?? false
        let requestedWindowId = v2UUID(params, "window_id")
        if params["window_id"] != nil && requestedWindowId == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid window selector. Use --window <id|ref|index> to target one window, or run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }
        if includeAllWindows, requestedWindowId != nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Choose either --window <id|ref|index> or --all-windows, not both. Run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }

        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }
        if let requestedWindowId {
            identifyParams["window_id"] = requestedWindowId.uuidString
        }
        let identifyPayload = v2Identify(params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let focusedWindowId = v2UUIDAny(focused["window_id"]) ?? v2UUIDAny(focused["window_ref"])
        return (
            V2WindowRouting(
                includeAllWindows: includeAllWindows,
                requestedWindowId: requestedWindowId,
                focused: focused,
                caller: caller,
                focusedWindowId: focusedWindowId
            ),
            nil
        )
    }

    private func v2WindowNotFoundResult(params: [String: Any], windowId: UUID) -> V2CallResult {
        .err(
            code: "not_found",
            message: "Window not found. Run `cmux list-windows` to see available windows, then retry with --window <id|ref|index>.",
            data: v2WindowSelectorDetails(params: params) ?? ["window_id": windowId.uuidString]
        )
    }

#if DEBUG
#endif

    func taskManagerTopPayload(includeProcesses: Bool) async throws -> [String: Any] {
        v2RefreshKnownRefs()

        let identifyPayload = v2Identify(params: [:])
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        var windowNodes: [[String: Any]] = []

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }
                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodes
                    )
                )
            }
        }
        v2AttachTopApplicationProcess(to: &windowNodes)

        let processSnapshot = await withTaskGroup(
            of: CmuxTopProcessSnapshot.self,
            returning: CmuxTopProcessSnapshot.self
        ) { group in
            group.addTask(priority: .utility) {
                CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
            }
            return await group.next()!
        }
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        var annotatedWindows = windowNodes
        let totalPIDs = v2AnnotateTopWindows(
            &annotatedWindows,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: annotatedWindows
        )

        return [
            "active": focused.isEmpty ? (NSNull() as Any) : focused,
            "caller": NSNull(),
            "sample": processSnapshot.samplePayload(),
            "totals": processSnapshot.summaryPayload(for: totalPIDs),
            "memory_diagnostic": memoryDiagnostic,
            "program_totals": aggregates.programs,
            "coding_agents": aggregates.codingAgents,
            "windows": annotatedWindows
        ]
    }

    private nonisolated func processAggregates(
        from processSnapshot: CmuxTopProcessSnapshot,
        totalPIDs: Set<Int>
    ) -> (programs: [[String: Any]], codingAgents: [[String: Any]]) {
        (
            programs: processSnapshot.programSummaryPayload(for: totalPIDs),
            codingAgents: processSnapshot.codingAgentSummaryPayload(for: totalPIDs)
        )
    }

    private nonisolated func v2SystemTop(params: [String: Any]) -> V2CallResult {
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: params)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              let includeProcesses = payload.removeValue(forKey: "include_processes") as? Bool,
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.top payload", data: nil)
        }
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        let totalPIDs = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes
        )

        payload["sample"] = processSnapshot.samplePayload()
        payload["totals"] = processSnapshot.summaryPayload(for: totalPIDs)
        payload["memory_diagnostic"] = memoryDiagnostic
        payload["program_totals"] = aggregates.programs
        payload["coding_agents"] = aggregates.codingAgents
        payload["windows"] = windowNodes
        return .ok(payload)
    }

    private nonisolated func v2SystemMemory(params: [String: Any]) -> V2CallResult {
        var baseParams = params
        baseParams["include_processes"] = false
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: baseParams)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.memory payload", data: nil)
        }
        func intParam(_ key: String) -> Int? {
            if let i = params[key] as? Int { return i }
            if let n = params[key] as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                let value = n.doubleValue
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else {
                    return nil
                }
                return n.intValue
            }
            if let s = params[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return Int(trimmed)
            }
            return nil
        }
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = intParam(key), (1...100).contains(value) else {
                invalidLimitKey = key
                return nil
            }
            return value
        }
        let topGroupLimitValue = groupLimitParam("top_group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let groupLimitValue = groupLimitParam("group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let topGroupLimit = topGroupLimitValue ?? groupLimitValue ?? 12
        let processSnapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            maximumAge: 2
        )
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        _ = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: false
        )
        payload["sample"] = processSnapshot.samplePayload()
        payload["memory_diagnostic"] = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes,
            topGroupLimit: topGroupLimit
        )
        return .ok(payload)
    }

    private func v2SystemTopBasePayload(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        if params["include_processes"] != nil, v2Bool(params, "include_processes") == nil { return .err(code: "invalid_params", message: "Missing or invalid include_processes", data: nil) }
        let includeProcesses = v2Bool(params, "include_processes") ?? false
        let routingResult = parseV2WindowRouting(params: params)
        if let error = routingResult.error { return error }
        guard let routing = routingResult.routing else {
            return .err(code: "internal_error", message: "Invalid window routing payload", data: nil)
        }

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowId == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowId ?? routing.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowId, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TopWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !routing.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodesForWindow
                    )
                )
            }
        }

        v2AttachTopApplicationProcess(to: &windowNodes, workspaceFilter: workspaceFilter)

        if let requestedWindowId = routing.requestedWindowId, !windowFound {
            return v2WindowNotFoundResult(params: params, windowId: requestedWindowId)
        }
        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": routing.focused.isEmpty ? (NSNull() as Any) : routing.focused,
            "caller": routing.caller.isEmpty ? (NSNull() as Any) : routing.caller,
            "include_processes": includeProcesses,
            "windows": windowNodes
        ])
    }

    private func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "kind": "window",
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TopWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "kind": "surface",
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id]),
                "webviews": []
            ]

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                let webContentPID = CmuxWebContentProcessIdentifier.pid(for: browserPanel.webView)
                let url = browserPanel.currentURL?.absoluteString ?? ""
                let webViewLifecycle = browserPanel.webViewLifecycleTopPayload()
                item["url"] = url
                item["browser_web_content_pid"] = v2OrNull(webContentPID)
                item["browser_webview_lifecycle_state"] = browserPanel.webViewLifecycleState.rawValue
                item["webviews"] = [
                    [
                        "kind": "webview",
                        "id": "\(panel.id.uuidString):webview",
                        "ref": "\(v2Ref(kind: .surface, uuid: panel.id)):webview",
                        "index": 0,
                        "surface_id": panel.id.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                        "title": browserPanel.displayTitle,
                        "url": url,
                        "pid": v2OrNull(webContentPID),
                        "lifecycle": webViewLifecycle
                    ] as [String: Any]
                ]
            } else {
                item["url"] = NSNull()
                item["browser_web_content_pid"] = NSNull()
            }
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return [
                "kind": "pane",
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? []
            ]
        }

        return [
            "kind": "workspace",
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "panes": panes,
            "tags": v2TopTagNodes(for: workspace)
        ]
    }

    private func v2TopTagNodes(for workspace: Workspace) -> [[String: Any]] {
        var tags: [[String: Any]] = []
        var seenKeys = Set<String>()

        for (index, entry) in workspace.sidebarStatusEntriesInDisplayOrder().enumerated() {
            let pid = workspace.agentPIDs[entry.key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: entry.key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: entry.key),
                "index": index,
                "key": entry.key,
                "value": entry.value,
                "icon": v2OrNull(entry.icon),
                "color": v2OrNull(entry.color),
                "url": v2OrNull(entry.url?.absoluteString),
                "priority": entry.priority,
                "format": entry.format.rawValue,
                "visible": true,
                "pid": v2OrNull(pid)
            ])
            seenKeys.insert(entry.key)
        }

        for key in workspace.agentPIDs.keys.sorted() where !seenKeys.contains(key) {
            let pid = workspace.agentPIDs[key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: key),
                "index": tags.count,
                "key": key,
                "value": "",
                "icon": NSNull(),
                "color": NSNull(),
                "url": NSNull(),
                "priority": 0,
                "format": "plain",
                "visible": false,
                "pid": v2OrNull(pid)
            ])
        }

        return tags
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

    nonisolated func v2OrNull(_ value: Any?) -> Any {
        // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
        if let value { return value }
        return NSNull()
    }

    nonisolated func v2NonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func v2MainSync<T>(_ body: @MainActor () -> T) -> T {
        let policyStack = Self.currentSocketCommandFocusAllowanceStack()
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                Self.withSocketCommandPolicyStack(policyStack) {
                    body()
                }
            }
        }
    }

    private nonisolated func v2Ok(id: Any?, result: Any) -> String {
        guard let idValue = Self.v2WireId(id),
              let payload = JSONValue(foundationObject: result) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.ok(id: idValue, result: payload)
    }

    /// Bridges a legacy `Any?` request id to the wire value: missing ids
    /// encode as JSON `null`; an unencodable id reports overall encode
    /// failure (the legacy `isValidJSONObject` behavior).
    private nonisolated static func v2WireId(_ id: Any?) -> JSONValue? {
        guard let id else { return .null }
        return JSONValue(foundationObject: id)
    }

    /// Bridge an async throws closure into a socket RPC response. Runs the work on a detached
    /// Task (so VMClient's URLSession hops are free to use any actor) and blocks the socket
    /// worker thread on a semaphore. Mirrors the auth.begin_sign_in pattern above.
    nonisolated func v2VmCall(
        id: Any?,
        timeoutSeconds: TimeInterval = 17 * 60,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String: Any], Error>?
        let task = Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "VM request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        switch result {
        case .success(let payload):
            return v2Ok(id: id, result: payload)
        case .failure(let error):
            return v2Error(
                id: id,
                code: "vm_error",
                message: String(describing: error)
            )
        case nil:
            return v2Error(
                id: id,
                code: "vm_error",
                message: "unknown vm error"
            )
        }
    }

    nonisolated func v2AsyncResultCall(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping () async -> V2CallResult
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult?
        let task = Task {
            result = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            task.cancel()
            return v2Error(
                id: id,
                code: "timeout",
                message: "Request timed out after \(Int(timeoutSeconds)) seconds"
            )
        }
        guard let result else {
            return v2Error(
                id: id,
                code: "request_error",
                message: "Request failed before returning a result"
            )
        }
        return v2Result(id: id, result)
    }

    nonisolated func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        guard let idValue = Self.v2WireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        var dataValue: JSONValue?
        if let data {
            guard let bridgedData = JSONValue(foundationObject: data) else {
                return ControlResponseEncoder.encodeFailureResponse
            }
            dataValue = bridgedData
        }
        return Self.v2Encoder.error(id: idValue, code: code, message: message, data: dataValue)
    }

    /// Interim `Any`-shaped twin of the package's `ControlCallResult`, kept
    /// while the command bodies still build Foundation payloads. Bodies
    /// migrate onto the typed DTO in the ControlCommandCoordinator stage.
    enum V2CallResult {
        case ok(Any)
        case err(code: String, message: String, data: Any?)
    }

    private nonisolated func v2Result(id: Any?, _ res: V2CallResult) -> String {
        switch res {
        case .ok(let payload):
            return v2Ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return v2Error(id: id, code: code, message: message, data: data)
        }
    }

    private nonisolated func v2UnsupportedWorkspaceAliasError(method: String, params: [String: Any]) -> V2CallResult? {
        guard method.hasPrefix("workspace."), params.keys.contains("window") else { return nil }
        return .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.unsupportedWindowParam",
                defaultValue: "Unsupported parameter `window`; use `window_id` with a window UUID or ref from `window.list`."
            ),
            data: [
                "method": method,
                "unsupported_param": "window",
                "supported_param": "window_id"
            ]
        )
    }

    private nonisolated func v2Encode(_ object: Any) -> String {
        guard let value = JSONValue(foundationObject: object) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.encode(value)
    }

    private func v2EnsureHandleRef(kind: ControlHandleKind, uuid: UUID) -> String {
        controlCommandCoordinator.ensureRef(kind: kind, uuid: uuid)
    }

    func v2ResolveHandleRef(_ handle: String) -> UUID? {
        controlCommandCoordinator.resolveRef(handle)
    }

    nonisolated func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        return v2MainSync { v2EnsureHandleRef(kind: kind, uuid: uuid) }
    }

    func v2WorkspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = v2EnsureHandleRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    func v2WorkspacePaneAndSurfaceRefs(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        return (
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspaceId),
            paneRef: paneId.map { v2EnsureHandleRef(kind: .pane, uuid: $0) },
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId)
        )
    }

    func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    // `internal` (not `private`): the workspace-domain conformance lives in a
    // separate extension file (`TerminalController+ControlWorkspaceContext.swift`),
    // whose `controlWorkspaceEnv` witness reproduces the legacy `v2WorkspaceEnv`
    // pre-resolution refs refresh and so must reach this member.
    func v2RefreshKnownRefs() {
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = v2EnsureHandleRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = v2EnsureHandleRef(kind: .surface, uuid: panelId)
                    }
                }
                // Mint workspace_group refs for groups that exist before any
                // workspace.group.* call so callers can pass `workspace_group:N`
                // immediately after restore (otherwise the first ref hand-off
                // happens only on `list`/`create`).
                for group in tm.workspaceGroups {
                    _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id)
                }
            }
        }
    }

    // MARK: - V2 Context Resolution

    nonisolated func v2ResolveTabManager(params: [String: Any]) -> TabManager? {
        // Prefer explicit window_id routing. Otherwise prefer group_id (group
        // methods are the only routing key for cross-window group ops, and
        // CLI helpers always inject caller workspace_id/surface_id, which
        // would otherwise win even when the group belongs to a different
        // window). Fall back to workspace/surface/pane lookup, then the
        // active window's TabManager.
        if v2HasNonNullParam(params, "window_id") {
            guard let windowId = v2UUID(params, "window_id") else { return nil }
            return v2MainSync { AppDelegate.shared?.tabManagerFor(windowId: windowId) }
        }
        if let groupId = v2UUID(params, "group_id") {
            if let tm = v2MainSync({ v2LocateTabManager(forGroupId: groupId) }) {
                return tm
            }
        }
        if let wsId = v2UUID(params, "workspace_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(tabId: wsId) }) {
                return tm
            }
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            if let tm = v2MainSync({ AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager }) {
                return tm
            }
        }
        if let paneId = v2UUID(params, "pane_id") {
            if let tm = v2MainSync({ v2LocatePane(paneId)?.tabManager }) {
                return tm
            }
        }
        return v2MainSync { tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager }
    }

    @MainActor
    private func v2LocateTabManager(forGroupId groupId: UUID) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tm = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if tm.workspaceGroups.contains(where: { $0.id == groupId }) {
                return tm
            }
        }
        return nil
    }

    /// Mirrors the former `v2ResolveTabManager` precedence for the
    /// ``ControlCommandContext`` window resolution, operating on selectors the
    /// coordinator already resolved through the shared handle registry: explicit
    /// `window_id` wins (a present-but-unresolvable one yields no target), then
    /// group, workspace, surface, pane, then the caller's window, then the
    /// active scriptable window. Lives here so it can read the controller's
    /// `private` `tabManager` / `v2LocateTabManager`.
    func resolveTabManager(routing: ControlRoutingSelectors) -> TabManager? {
        if routing.hasWindowIDParam {
            guard let windowId = routing.windowID else { return nil }
            return AppDelegate.shared?.tabManagerFor(windowId: windowId)
        }
        if let groupId = routing.groupID,
           let tm = v2LocateTabManager(forGroupId: groupId) {
            return tm
        }
        if let workspaceId = routing.workspaceID,
           let tm = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) {
            return tm
        }
        if let surfaceId = routing.surfaceID,
           let tm = AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager {
            return tm
        }
        if let paneId = routing.paneID,
           let tm = v2LocatePane(paneId)?.tabManager {
            return tm
        }
        return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }

    func v2ResolveWindowId(tabManager: TabManager?) -> UUID? {
        guard let tabManager else { return nil }
        return v2MainSync { AppDelegate.shared?.windowId(for: tabManager) }
    }

    private func v2ResolveWorkspaceOwner(_ workspaceId: UUID) -> TabManager? {
        v2MainSync { AppDelegate.shared?.tabManagerFor(tabId: workspaceId) }
    }

    // MARK: - V2 Workspace Methods







    @MainActor

    func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "set_description", "clear_description",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread",
            "set_color", "clear_color"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "set_description":
                guard let descriptionRaw = v2String(params, "description"),
                      !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid description", data: nil)
                    return
                }
                tabManager.setCustomDescription(tabId: workspace.id, description: descriptionRaw)
                finish(["description": v2OrNull(workspace.customDescription)])

            case "clear_description":
                tabManager.clearCustomDescription(tabId: workspace.id)
                finish(["description": NSNull()])

            case "move_up":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: max(currentIndex - 1, 0))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: min(currentIndex + 1, tabManager.tabs.count - 1))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
                finish()

            case "set_color":
                guard let colorRaw = v2String(params, "color"),
                      !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid color", data: nil)
                    return
                }
                let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Resolve named colors from the effective palette, including file-defined additions.
                let effectivePalette = WorkspaceTabColorSettings.palette()
                let hex: String
                if let entry = effectivePalette.first(where: {
                    $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
                }) {
                    hex = entry.hex
                } else if let normalized = WorkspaceTabColorSettings.normalizedHex(colorInput) {
                    hex = normalized
                } else {
                    let colorNames = effectivePalette.map(\.name)
                    result = .err(code: "invalid_params", message: "Invalid color. Use a hex value (#RRGGBB) or a named color.", data: [
                        "named_colors": colorNames
                    ])
                    return
                }
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                finish(["color": hex])

            case "clear_color":
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                finish(["color": NSNull()])

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    // MARK: - V2 Surface Methods

    @MainActor
    @discardableResult
    func closeSurfaceRecordingHistory(in workspace: Workspace, surfaceId: UUID, force: Bool) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            if force {
                return workspace.requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }

        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = v2UUID(params, "pane_id"),
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }















    // `internal` (not `private`): the Pane domain's app conformance forwards
    // `pane.join` to this body. The Surface domain extraction will relocate it.
    func v2SurfaceMove(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let requestedPaneUUID = v2UUID(params, "pane_id")
        let requestedWorkspaceUUID = v2UUID(params, "workspace_id")
        let requestedWindowUUID = v2UUID(params, "window_id")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let explicitIndex = v2Int(params, "index")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        let anchorCount = (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if anchorCount > 1 {
            return .err(code: "invalid_params", message: "Specify at most one of before_surface_id or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }

            guard let source = app.locateSurface(surfaceId: surfaceId),
                  let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceId)
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)

            var targetWindowId = source.windowId
            var targetTabManager = source.tabManager
            var targetWorkspace = sourceWorkspace
            var targetPane = sourcePane ?? sourceWorkspace.bonsplitController.focusedPaneId ?? sourceWorkspace.bonsplitController.allPaneIds.first
            var targetIndex = explicitIndex

            if let anchorSurfaceId = beforeSurfaceId ?? afterSurfaceId {
                guard let anchor = app.locateSurface(surfaceId: anchorSurfaceId),
                      let anchorWorkspace = anchor.tabManager.tabs.first(where: { $0.id == anchor.workspaceId }),
                      let anchorPane = anchorWorkspace.paneId(forPanelId: anchorSurfaceId),
                      let anchorIndex = anchorWorkspace.indexInPane(forPanelId: anchorSurfaceId) else {
                    result = .err(code: "not_found", message: "Anchor surface not found", data: ["surface_id": anchorSurfaceId.uuidString])
                    return
                }
                targetWindowId = anchor.windowId
                targetTabManager = anchor.tabManager
                targetWorkspace = anchorWorkspace
                targetPane = anchorPane
                targetIndex = (beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)
            } else if let paneUUID = requestedPaneUUID {
                guard let located = v2LocatePane(paneUUID) else {
                    result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
                targetWindowId = located.windowId
                targetTabManager = located.tabManager
                targetWorkspace = located.workspace
                targetPane = located.paneId
            } else if let workspaceUUID = requestedWorkspaceUUID {
                guard let tm = app.tabManagerFor(tabId: workspaceUUID),
                      let ws = tm.tabs.first(where: { $0.id == workspaceUUID }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceUUID.uuidString])
                    return
                }
                targetTabManager = tm
                targetWorkspace = ws
                targetWindowId = app.windowId(for: tm) ?? targetWindowId
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            } else if let windowUUID = requestedWindowUUID {
                guard let tm = app.tabManagerFor(windowId: windowUUID) else {
                    result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWindowId = windowUUID
                targetTabManager = tm
                guard let selectedWorkspaceId = tm.selectedTabId,
                      let ws = tm.tabs.first(where: { $0.id == selectedWorkspaceId }) else {
                    result = .err(code: "not_found", message: "Target window has no selected workspace", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWorkspace = ws
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let destinationPane = targetPane else {
                result = .err(code: "not_found", message: "No destination pane", data: nil)
                return
            }

            if targetWorkspace.id == sourceWorkspace.id {
                guard sourceWorkspace.moveSurface(panelId: surfaceId, toPane: destinationPane, atIndex: targetIndex, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to move surface", data: nil)
                    return
                }
                result = .ok([
                    "window_id": targetWindowId.uuidString,
                    "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                    "workspace_id": targetWorkspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                    "pane_id": destinationPane.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ])
                return
            }

            guard let transfer = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach surface", data: nil)
                return
            }

            if targetWorkspace.attachDetachedSurface(transfer, inPane: destinationPane, atIndex: targetIndex, focus: focus) == nil {
                // Roll back to source workspace if attach fails.
                let rollbackPane = sourcePane.flatMap { sp in sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == sp }) }
                    ?? sourceWorkspace.bonsplitController.focusedPaneId
                    ?? sourceWorkspace.bonsplitController.allPaneIds.first
                if let rollbackPane {
                    _ = sourceWorkspace.attachDetachedSurface(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to destination", data: nil)
                return
            }

            if focus {
                _ = app.focusMainWindow(windowId: targetWindowId)
                setActiveTabManager(targetTabManager)
                targetTabManager.selectWorkspace(targetWorkspace)
            }

            result = .ok([
                "window_id": targetWindowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                "workspace_id": targetWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }



    func v2DebugTerminals(params _: [String: Any]) -> V2CallResult {
        var payload: [String: Any]?

        v2MainSync {
            guard let app = AppDelegate.shared else { return }

            struct MappedTerminalLocation {
                let windowIndex: Int
                let windowId: UUID
                let window: NSWindow?
                let workspaceIndex: Int
                let workspaceSelected: Bool
                let workspace: Workspace
                let terminalPanel: TerminalPanel
                let paneId: PaneID?
                let paneIndex: Int?
                let surfaceIndex: Int
                let selectedInPane: Bool?
                let bonsplitTabId: TabID?
            }

            func nonEmpty(_ raw: String?) -> String? {
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            func rectPayload(_ rect: CGRect) -> [String: Double] {
                [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height)
                ]
            }

            func objectPointerString(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return String(describing: Unmanaged.passUnretained(object).toOpaque())
            }

            func ghosttyPointerString(_ surface: ghostty_surface_t?) -> String {
                guard let surface else { return "nil" }
                return String(describing: surface)
            }

            func className(_ object: AnyObject?) -> String? {
                guard let object else { return nil }
                return String(describing: type(of: object))
            }

            let iso8601Formatter = ISO8601DateFormatter()
            let now = Date()

            func iso8601String(_ date: Date?) -> String? {
                guard let date else { return nil }
                return iso8601Formatter.string(from: date)
            }

            func ageSeconds(since date: Date?) -> Double? {
                guard let date else { return nil }
                return (now.timeIntervalSince(date) * 1000).rounded() / 1000
            }

            @MainActor
            func superviewClassChain(for view: NSView, limit: Int = 8) -> [String] {
                var chain: [String] = [String(describing: type(of: view))]
                var currentSuperview = view.superview
                while chain.count < limit, let nextSuperview = currentSuperview {
                    chain.append(String(describing: type(of: nextSuperview)))
                    currentSuperview = nextSuperview.superview
                }
                if currentSuperview != nil {
                    chain.append("...")
                }
                return chain
            }

            let windows = app.scriptableMainWindows()
            let windowIndexById = Dictionary(
                uniqueKeysWithValues: windows.enumerated().map { ($0.element.windowId, $0.offset) }
            )

            @MainActor
            func resolvedWindowMetadata(for window: NSWindow?) -> (windowId: UUID?, windowIndex: Int?) {
                guard let window else { return (nil, nil) }

                if let match = windows.enumerated().first(where: { _, state in
                    guard let stateWindow = state.window else { return false }
                    return stateWindow === window || stateWindow.windowNumber == window.windowNumber
                }) {
                    return (match.element.windowId, match.offset)
                }

                guard let raw = window.identifier?.rawValue else { return (nil, nil) }
                let prefix = "cmux.main."
                guard raw.hasPrefix(prefix),
                      let parsedWindowId = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                    return (nil, nil)
                }
                return (parsedWindowId, windowIndexById[parsedWindowId])
            }

            var mappedLocations: [ObjectIdentifier: MappedTerminalLocation] = [:]
            for (windowIndex, state) in windows.enumerated() {
                let tabManager = state.tabManager
                for (workspaceIndex, workspace) in tabManager.tabs.enumerated() {
                    let paneIndexById = Dictionary(
                        uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.enumerated().map {
                            ($0.element.id, $0.offset)
                        }
                    )
                    var selectedInPaneByPanelId: [UUID: Bool] = [:]
                    for paneId in workspace.bonsplitController.allPaneIds {
                        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
                        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                            selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
                        }
                    }

                    for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
                        guard let terminalPanel = panel as? TerminalPanel else { continue }
                        mappedLocations[ObjectIdentifier(terminalPanel.surface)] = MappedTerminalLocation(
                            windowIndex: windowIndex,
                            windowId: state.windowId,
                            window: state.window,
                            workspaceIndex: workspaceIndex,
                            workspaceSelected: workspace.id == tabManager.selectedTabId,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            paneId: workspace.paneId(forPanelId: terminalPanel.id),
                            paneIndex: workspace.paneId(forPanelId: terminalPanel.id).flatMap { paneIndexById[$0.id] },
                            surfaceIndex: surfaceIndex,
                            selectedInPane: selectedInPaneByPanelId[terminalPanel.id],
                            bonsplitTabId: workspace.surfaceIdFromPanelId(terminalPanel.id)
                        )
                    }
                }
            }

            let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()
            let terminals: [[String: Any]] = surfaces.enumerated().map { index, terminalSurface in
                let mapped = mappedLocations[ObjectIdentifier(terminalSurface)]
                let hostedView = terminalSurface.hostedView
                let hostedWindow = mapped?.window ?? terminalSurface.uiWindow
                let fallbackWindowMetadata = resolvedWindowMetadata(for: hostedWindow)
                let resolvedWindowId = mapped?.windowId ?? fallbackWindowMetadata.windowId
                let resolvedWindowIndex = mapped?.windowIndex ?? fallbackWindowMetadata.windowIndex
                let workspace = mapped?.workspace
                let panelId = mapped?.terminalPanel.id ?? terminalSurface.id
                let portalState = hostedView.portalBindingGuardState()
                let portalHostLease = terminalSurface.debugPortalHostLease()
                let gitBranchState = workspace?.panelGitBranches[panelId]
                let listeningPorts = (workspace?.surfaceListeningPorts[panelId] ?? []).sorted()
                let title = workspace?.panelTitle(panelId: panelId)
                let paneId = mapped?.paneId
                let treeVisible = mapped?.bonsplitTabId != nil && paneId != nil
                let ttyName = workspace?.surfaceTTYNames[panelId]
                let currentDirectory = nonEmpty(workspace?.panelDirectories[panelId] ?? mapped?.terminalPanel.directory)
                let teardownRequest = terminalSurface.debugTeardownRequest()
                let lastKnownWorkspaceId = terminalSurface.debugLastKnownWorkspaceId()

                var item: [String: Any] = [
                    "index": index,
                    "mapped": mapped != nil,
                    "tree_visible": treeVisible,
                    "window_index": v2OrNull(resolvedWindowIndex),
                    "window_id": v2OrNull(resolvedWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: resolvedWindowId),
                    "window_number": v2OrNull(hostedWindow?.windowNumber),
                    "window_key": hostedWindow?.isKeyWindow ?? false,
                    "window_main": hostedWindow?.isMainWindow ?? false,
                    "window_visible": hostedWindow?.isVisible ?? false,
                    "window_occluded": hostedWindow.map { !$0.occlusionState.contains(.visible) } ?? false,
                    "window_identifier": v2OrNull(hostedWindow?.identifier?.rawValue),
                    "window_title": v2OrNull(nonEmpty(hostedWindow?.title)),
                    "window_class": v2OrNull(className(hostedWindow)),
                    "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                    "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                    "window_level": v2OrNull(hostedWindow?.level.rawValue),
                    "window_frame": hostedWindow.map { rectPayload($0.frame) } ?? NSNull(),
                    "workspace_index": v2OrNull(mapped?.workspaceIndex),
                    "workspace_id": v2OrNull(workspace?.id.uuidString),
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace?.id),
                    "workspace_title": v2OrNull(workspace?.title),
                    "workspace_selected": v2OrNull(mapped?.workspaceSelected),
                    "pane_index": v2OrNull(mapped?.paneIndex),
                    "pane_id": v2OrNull(paneId?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id),
                    "surface_index": v2OrNull(mapped?.surfaceIndex),
                    "surface_index_in_pane": v2OrNull(workspace?.indexInPane(forPanelId: panelId)),
                    "surface_id": panelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panelId),
                    "surface_title": v2OrNull(title),
                    "surface_focused": v2OrNull(workspace.map { panelId == $0.focusedPanelId }),
                    "surface_selected_in_pane": v2OrNull(mapped?.selectedInPane),
                    "surface_pinned": v2OrNull(workspace.map { $0.isPanelPinned(panelId) }),
                    "surface_context": terminalSurface.debugSurfaceContextLabel(),
                    "surface_created_at": v2OrNull(iso8601String(terminalSurface.debugCreatedAt())),
                    "surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugCreatedAt())),
                    "runtime_surface_created_at": v2OrNull(iso8601String(terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "runtime_surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "bonsplit_tab_id": v2OrNull(mapped?.bonsplitTabId?.uuid.uuidString),
                    "terminal_object_ptr": objectPointerString(terminalSurface),
                    "ghostty_surface_ptr": ghosttyPointerString(terminalSurface.surface),
                    "runtime_surface_ready": terminalSurface.surface != nil,
                    "hosted_view_ptr": objectPointerString(hostedView),
                    "hosted_view_class": className(hostedView) ?? "nil",
                    "hosted_view_in_window": terminalSurface.isViewInWindow,
                    "hosted_view_in_headless_bootstrap_window": terminalSurface.isHeadlessStartupWindow(hostedView.window),
                    "hosted_view_has_superview": hostedView.superview != nil,
                    "hosted_view_hidden": hostedView.isHidden,
                    "hosted_view_hidden_or_ancestor_hidden": hostedView.isHiddenOrHasHiddenAncestor,
                    "hosted_view_alpha": hostedView.alphaValue,
                    "hosted_view_visible_in_ui": hostedView.debugPortalVisibleInUI,
                    "hosted_view_superview_chain": superviewClassChain(for: hostedView),
                    "surface_view_first_responder": hostedView.isSurfaceViewFirstResponder(),
                    "hosted_view_frame": rectPayload(hostedView.frame),
                    "hosted_view_bounds": rectPayload(hostedView.bounds),
                    "hosted_view_frame_in_window": rectPayload(hostedView.debugPortalFrameInWindow),
                    "portal_binding_state": portalState.state,
                    "portal_binding_generation": v2OrNull(portalState.generation),
                    "portal_host_id": v2OrNull(portalHostLease.hostId),
                    "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                    "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                    "tty": v2OrNull(ttyName),
                    "current_directory": v2OrNull(currentDirectory),
                    "requested_working_directory": v2OrNull(nonEmpty(terminalSurface.requestedWorkingDirectory)),
                    "initial_command": v2OrNull(nonEmpty(terminalSurface.debugInitialCommand())),
                    "tmux_start_command": v2OrNull(nonEmpty(terminalSurface.debugTmuxStartCommand())),
                    "git_branch": v2OrNull(nonEmpty(gitBranchState?.branch)),
                    "git_dirty": v2OrNull(gitBranchState?.isDirty),
                    "listening_ports": listeningPorts,
                    "key_state_indicator": v2OrNull(nonEmpty(terminalSurface.currentKeyStateIndicatorText)),
                    "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                    "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                    "teardown_requested": teardownRequest.requestedAt != nil,
                    "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                    "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                    "teardown_requested_reason": v2OrNull(nonEmpty(teardownRequest.reason))
                ]

                if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                    item["surface_title"] = fallbackTitle
                }
                return item
            }

            payload = [
                "count": terminals.count,
                "terminals": terminals
            ]
        }

        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }





    // `TerminalTextRawSnapshot`, `TerminalTextPayload`, and
    // `TerminalTextPayloadError`, plus the pure payload assembly
    // (`TerminalTextPayload.make`) and `String.terminalTextTail`, now live in
    // `CmuxTerminal`. The Ghostty-pointer readers below stay app-side because
    // they call `ghostty_surface_read_text` directly (engine-coupled residue,
    // revisit when CmuxTerminalEngine lands).
    func readTerminalTextRawSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard terminalPanel.surface.surface != nil else { return nil }
        if includeScrollback {
            return TerminalTextRawSnapshot(
                viewport: nil,
                screen: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_SCREEN),
                history: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_SURFACE),
                active: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_ACTIVE)
            )
        }
        return TerminalTextRawSnapshot(
            viewport: readTerminalSelectionText(terminalPanel: terminalPanel, pointTag: GHOSTTY_POINT_VIEWPORT),
            screen: nil,
            history: nil,
            active: nil
        )
    }

    private func readTerminalSelectionText(terminalPanel: TerminalPanel, pointTag: ghostty_point_tag_e) -> String? {
        guard let surface = terminalPanel.surface.surface else { return nil }
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    // Relaxed from `private` to `internal`: the relocated v1
    // `readTerminalTextBase64(surfaceArg:)` body (now in
    // `TerminalController+ControlSurfaceSendNotifyV1.swift`) calls this shared
    // panel-level reader, which stays here because the v2 read path also uses it.
    func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "readTerminalTextBase64") != nil else {
            return "ERROR: Terminal surface not found"
        }
        guard let snapshot = readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback
        ) else {
            return "ERROR: Terminal surface not found"
        }
        switch TerminalTextPayload.make(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        bindingAction: String = "write_screen_file:copy,vt",
        lineLimit: Int?,
        normalizeLineEndings: Bool = true
    ) -> String? {
        var actionSucceeded = false
        let exportedPath = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            let ok = terminalPanel.performBindingAction(bindingAction)
            actionSucceeded = ok
            return ok
        }
        #if DEBUG
        cmuxDebugLog("mobile.vtExport action=\(bindingAction) succeeded=\(actionSucceeded) hasPath=\(exportedPath != nil)")
        #endif
        guard let exportedPath = Self.normalizedExportedScreenPath(exportedPath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let rawOutput = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = normalizeLineEndings
            ? Self.normalizedMobileVTExportText(rawOutput)
            : rawOutput
        if let lineLimit {
            output = output.terminalTextTail(maxLines: lineLimit)
        }
        return output
    }

    private func readPlainTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        let response = readTerminalTextBase64(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        allowVTExport: Bool = true
    ) -> String? {
        if includeScrollback,
           allowVTExport,
           let vtOutput = readTerminalTextFromVTExportForSnapshot(
               terminalPanel: terminalPanel,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        return readPlainTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    func readTerminalTextForHibernationFingerprint(
        terminalPanel: TerminalPanel,
        lineLimit: Int
    ) -> String? {
        // This runs from the periodic hibernation timer. Sample the visible tail
        // only, rather than copying full scrollback every cycle.
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: false,
            lineLimit: lineLimit,
            allowVTExport: false
        )
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTerminalTextForSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }


    /// Applies the iMessage-mode side effects for a `feed.push` event. Kept on
    /// the controller (not lifted into ``ControlFeedWorker``) because it reaches
    /// the live `AppDelegate` / `TabManager` per-workspace state; the package
    /// worker drives it through
    /// ``ControlFeedWorkerReading/pushEvent(eventPayload:waitTimeoutSeconds:)``,
    /// which calls this from `controlFeedPushEvent`. `internal` (not `private`) so
    /// the conformance extension file can reach it.
    nonisolated func v2ApplyIMessageModeSideEffects(for event: WorkstreamEvent) {
        guard event.hookEventName == .userPromptSubmit || event.hookEventName == .stop || event.hookEventName == .subagentStop,
              let rawWorkspaceId = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawWorkspaceId.isEmpty
        else { return }

        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        switch event.hookEventName {
        case .userPromptSubmit:
            v2MainSync {
                guard let workspaceId = v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handlePromptSubmit(
                    workspaceId: workspaceId,
                    message: event.submittedPromptMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        case .stop, .subagentStop:
            let assistantFinalMessage = event.assistantFinalMessage
            Task { @MainActor [weak self, rawWorkspaceId, assistantFinalMessage, iMessageModeEnabled] in
                guard let self,
                      let workspaceId = self.v2UUIDAny(rawWorkspaceId) else { return }
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { return }
                _ = tabManager.handleAssistantFinalMessage(
                    workspaceId: workspaceId,
                    message: assistantFinalMessage,
                    iMessageModeEnabled: iMessageModeEnabled
                )
            }
        default:
            break
        }
    }

    // MARK: - V2 Browser Methods

    func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                result = error
                return
            }
            let surfaceId = resolvedSurface.surfaceId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    /// Value snapshot of a resolved browser surface for socket-worker handlers:
    /// resolution happens on the main actor, the JS-evaluating body runs off it.
    private struct V2BrowserPanelContext {
        let workspaceId: UUID
        let surfaceId: UUID
        let browserPanel: BrowserPanel
        let webView: WKWebView
    }

    /// Off-main counterpart of v2BrowserWithPanel for the socket-worker browser
    /// methods: the panel is resolved inside v2MainSync, but `body` runs on the
    /// calling (worker) thread so blocking JavaScript waits never hold the main
    /// actor. `body` must wrap any UI/model access of its own in v2MainSync.
    private nonisolated func v2BrowserWithPanelContext(
        params: [String: Any],
        _ body: (_ ctx: V2BrowserPanelContext) -> V2CallResult
    ) -> V2CallResult {
        var resolved: V2BrowserPanelContext?
        var failure: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                failure = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                failure = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                failure = error
                return
            }
            guard let surfaceId = resolvedSurface.surfaceId else {
                failure = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                failure = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            resolved = V2BrowserPanelContext(
                workspaceId: ws.id,
                surfaceId: surfaceId,
                browserPanel: browserPanel,
                webView: browserPanel.webView
            )
        }
        guard let resolved else { return failure }
        return body(resolved)
    }

    func v2ResolveBrowserSurfaceId(
        params: [String: Any],
        workspace: Workspace
    ) -> (surfaceId: UUID?, error: V2CallResult?) {
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return (surfaceId, nil)
        }
        if let paneId = v2UUID(params, "pane_id") {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneId.uuidString])
                )
            }
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = workspace.panelIdFromSurfaceId(selectedTab.id) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": paneId.uuidString])
                )
            }
            return (selectedSurface, nil)
        }
        return (workspace.focusedPanelId, nil)
    }

    nonisolated func v2JSONLiteral(_ value: Any) -> String {
        v2BrowserControl.jsonLiteral(value)
    }

    nonisolated func v2NormalizeJSValue(_ value: Any?) -> Any {
        v2BrowserControl.normalizeJSValue(value) { $0 is V2BrowserUndefinedSentinel }
    }

    enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    /// True when a page-world JS failure looks like a CSP block of eval/function
    /// construction (script-src without 'unsafe-eval'). That is the only failure
    /// the isolated-world retry is meant to recover from; gating on it keeps the
    /// retry from re-running a script that already failed for an ordinary reason
    /// (a thrown exception, a timeout), which would duplicate any side effect the
    /// script performed before throwing and could return a value from the wrong
    /// JS context.
    private nonisolated func v2BrowserFailureLooksLikeCSPEvalBlock(_ message: String) -> Bool {
        v2BrowserControl.failureLooksLikeCSPEvalBlock(message)
    }

    /// Sendable stand-in for `WKContentWorld` so nonisolated callers can pick a world without
    /// touching the main-actor-isolated `WKContentWorld.page`/`.defaultClient` statics. The real
    /// world is resolved on the main actor inside `v2RunJavaScript`.
    // `internal` (not `private`): named at the `v2RunJavaScript(..., world: .page)`
    // call sites in the cross-file browser console/errors witnesses
    // (`TerminalController+ControlBrowserConsoleErrorsStateContext.swift`).
    enum V2JSContentWorld: Sendable { case page, isolated }

    // `internal` (not `private`): the browser console/errors witnesses in
    // `TerminalController+ControlBrowserConsoleErrorsStateContext.swift` evaluate
    // the console/error ring read/clear scripts through this synchronous eval,
    // matching the cookies/storage cross-file witness pattern.
    nonisolated func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        world: V2JSContentWorld
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        // Capture the held browser-control service (a Sendable value) rather than
        // `self`, reusing the already-initialized instance for error description.
        let browserControl = v2BrowserControl
        // The evaluator only ever runs on the main actor (Thread.isMainThread branch or
        // DispatchQueue.main.async below), so assumeIsolated is safe and lets us touch the
        // main-actor WKWebView APIs and WKContentWorld statics without spurious isolation warnings.
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            MainActor.assumeIsolated {
                let contentWorld: WKContentWorld = (world == .page) ? .page : .defaultClient
                if preferAsync, #available(macOS 11.0, *) {
                    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                        switch result {
                        case .success(let value):
                            finish(value, nil)
                        case .failure(let error):
                            finish(nil, browserControl.describeJavaScriptError(error))
                        }
                    }
                } else {
                    webView.evaluateJavaScript(script) { value, error in
                        if let error {
                            finish(nil, browserControl.describeJavaScriptError(error))
                        } else {
                            finish(value, nil)
                        }
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
#if DEBUG
            cmuxDebugLog(
                "browser.jsRun.timeout preferAsync=\(preferAsync) " +
                "world=\(world == .page ? "page" : "isolated") timeout=\(timeoutSeconds)"
            )
#endif
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    /// The bounded blocking-await primitive the worker-lane browser JS-eval core
    /// blocks on. The behavior lives in CmuxControlSocket's
    /// ``ControlBrowserEvalAwaiter`` (a pure, app-agnostic `Sendable` value with
    /// no `WebKit`/main-actor/per-surface reach); this forwards to it so the many
    /// still-app-side eval-core callers keep one call site. Stays here as the
    /// shared shim because those callers (`v2RunJavaScript`,
    /// `v2EnsureBrowserDocumentLoaded`, the screenshot/download waits) remain in
    /// the app target until their WebKit-reaching bodies migrate.
    private nonisolated func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        Self.browserEvalAwaiter.await(timeout: timeout, start: start)
    }

    private nonisolated func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> V2BrowserWaitOutcome {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true ? .met : .timedOut
        case .failure(let message):
            return .evaluationFailed(message)
        }
    }

    private enum V2BrowserWaitOutcome {
        case met
        case timedOut
        case evaluationFailed(String)
    }

    private nonisolated func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    private nonisolated func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        v2MainSync {
            let ref = "@e\(v2BrowserNextElementOrdinal)"
            v2BrowserNextElementOrdinal += 1
            v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
            return ref
        }
    }

    private nonisolated func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2MainSync({ v2BrowserElementRefs[refKey] }), entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    private nonisolated func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2MainSync { v2BrowserFrameSelectorBySurface[surfaceId] }
    }

    /// A WKWebView that has never committed a navigation has no JavaScript context, so the
    /// first evaluateJavaScript/callAsyncJavaScript call can hang for its full timeout. A
    /// URL-less browser surface never mounts its webview either (no render, no host window),
    /// so a raw webView.load() would not progress. Kick such surfaces through the panel's
    /// normal navigate path (which hosts the webview) to about:blank, and wait for the URL
    /// to commit (KVO, bounded by `timeout`) before any automation JS runs against them.
    private nonisolated func v2EnsureBrowserDocumentLoaded(
        _ webView: WKWebView,
        surfaceId: UUID,
        timeout: TimeInterval = 3.0
    ) {
        let needsKick: Bool = v2MainSync {
            guard webView.url == nil,
                  !webView.isLoading,
                  webView.backForwardList.currentItem == nil else { return false }
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
                  let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let browserPanel = workspace.browserPanel(for: surfaceId),
                  let blankURL = URL(string: "about:blank") else {
#if DEBUG
                cmuxDebugLog("browser.jsKick.locateFailed surface=\(surfaceId.uuidString.prefix(5))")
#endif
                return false
            }
            // Discarded/restored tabs also have a fresh nil-url webview but preserve
            // the user's page; bring that back instead of clobbering it with blank.
            if browserPanel.restoreDiscardedWebViewIfNeeded(reason: "automation-js") {
                return true
            }
            if let preserved = browserPanel.currentURL {
                browserPanel.navigate(to: preserved)
            } else {
                browserPanel.navigate(to: blankURL)
            }
            return true
        }
        guard needsKick else { return }

        // Register synchronously and invalidate after the await (both on main) so
        // the observation cannot leak when the commit never arrives before timeout.
        nonisolated(unsafe) var observation: NSKeyValueObservation?
        let committed = v2AwaitCallback(timeout: timeout) { (finish: @escaping (Bool) -> Void) in
            v2MainSync {
                observation = webView.observe(\.url, options: [.initial, .new]) { observed, _ in
                    guard observed.url != nil else { return }
                    finish(true)
                }
            }
        }
        v2MainSync {
            observation?.invalidate()
            observation = nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.jsKick surface=\(surfaceId.uuidString.prefix(5)) " +
            "committed=\(committed == true) url=\(v2MainSync { webView.url?.absoluteString ?? "nil" })"
        )
#endif
    }

    nonisolated func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true,
        onIsolatedWorldFallback: (() -> Void)? = nil
    ) -> V2JavaScriptResult {
        v2EnsureBrowserDocumentLoaded(webView, surfaceId: surfaceId)
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """

        var rawResult: V2JavaScriptResult
        if #available(macOS 11.0, *) {
            rawResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                world: .page
            )
        } else {
            let evaluateFallback = """
            (async () => {
              \(asyncFunctionBody)
            })()
            """
            rawResult = v2RunJavaScript(webView, script: evaluateFallback, timeout: timeout, world: .page)
        }

        // Retry in the isolated world only when page CSP blocked eval/function construction
        // (script-src without 'unsafe-eval'). That block applies to callAsyncJavaScript and page
        // eval() but not to isolated content worlds, which share the DOM, so DOM-only automation
        // scripts and DOM-reading user evals (document.title) still work there.
        //
        // Gating on the CSP signature matters: a script can fail in the page world for ordinary
        // reasons (a thrown exception, a timeout) after performing a side effect, and an
        // unconditional retry would run it a second time and duplicate that side effect, or return
        // a value from the isolated world that differs from the page world with no visible signal.
        //
        // The isolated world cannot see page-world JS globals (window.reactRoot set by the page's
        // own scripts). For internal automation (useEval == false) that is transparent. For a
        // user-supplied browser.eval (useEval == true) it matters, so we invoke
        // onIsolatedWorldFallback to let browser.eval annotate the result with the content world.
        if case .failure(let pageMessage) = rawResult,
           v2BrowserFailureLooksLikeCSPEvalBlock(pageMessage),
           #available(macOS 11.0, *) {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                world: .isolated
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
                onIsolatedWorldFallback?()
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    nonisolated func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        v2MainSync {
            var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
            logs.append(request)
            if logs.count > 256 {
                logs.removeFirst(logs.count - 256)
            }
            v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
        }
    }

    /// The recorded not-supported network-request log for `surfaceId` (empty
    /// when nothing recorded). Read accessor co-located with the private state so
    /// the `ControlBrowserContext` conformance (a separate file) can serve
    /// `browser.network.requests` without widening the storage's visibility.
    func v2BrowserUnsupportedNetworkRequests(surfaceId: UUID) -> [[String: Any]] {
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
    }

    private nonisolated func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2MainSync { v2BrowserDialogQueueBySurface[surfaceId] ?? [] }
        return queue.enumerated().map { index, d in
            [
                "index": index,
                "type": d.type,
                "message": d.message,
                "default_text": v2OrNull(d.defaultText)
            ]
        }
    }

    func enqueueBrowserDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        queue.append(V2BrowserPendingDialog(type: type, message: message, defaultText: defaultText, responder: responder))
        if queue.count > 16 {
            // Keep bounded memory while preserving FIFO semantics for newest entries.
            queue.removeFirst(queue.count - 16)
        }
        v2BrowserDialogQueueBySurface[surfaceId] = queue
    }

    // v2BrowserPopDialog and v2BrowserEnsureInitScriptsApplied were drained with
    // the browser addscript/dialog domain (CmuxControlSocket
    // ControlCommandCoordinator+BrowserScriptDialog): both were dead private
    // holdovers with zero callers in Sources/CLI/cmuxTests (init scripts are now
    // applied only via the WKUserScript registration in the addinitscript witness,
    // and the dialog queue is popped in-page by the dialog-respond JS, not by a
    // Swift pop helper).

    private func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

    // MARK: - Project

    // MARK: - Project state driving (debug RPC for autonomous iteration)

    private func v2ResolveProjectPanel(params: [String: Any]) -> (Workspace, ProjectPanel)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var result: (Workspace, ProjectPanel)?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId,
                  let panel = ws.panels[surfaceId] as? ProjectPanel else { return }
            result = (ws, panel)
        }
        return result
    }

    // MARK: - Browser

    private func v2BrowserDisabledExternalOpenResult(
        rawURL: String? = nil,
        url: URL?,
        tabManager: TabManager?
    ) -> V2CallResult {
        if let rawURL, url == nil {
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: ["url": rawURL]
            )
        }
        guard let url else {
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        }

        var result: V2CallResult = .err(
            code: "external_open_failed",
            message: "Failed to open URL externally",
            data: ["url": url.absoluteString]
        )
        v2MainSync {
            guard NSWorkspace.shared.open(url) else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": v2OrNull(nil),
                "workspace_ref": v2Ref(kind: .workspace, uuid: nil),
                "pane_id": v2OrNull(nil),
                "pane_ref": v2Ref(kind: .pane, uuid: nil),
                "surface_id": v2OrNull(nil),
                "surface_ref": v2Ref(kind: .surface, uuid: nil),
                "created_split": false,
                "opened_externally": true,
                "browser_disabled": true,
                "placement_strategy": "external_browser_disabled",
                "url": url.absoluteString
            ])
        }
        return result
    }

    private nonisolated func v2BrowserNotFoundDiagnostics(
        surfaceId: UUID,
        browserPanel: BrowserPanel,
        selector: String
    ) -> [String: Any] {
        let script = v2BrowserControl.notFoundDiagnosticsScript(selector: selector)

        switch v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script, timeout: 4.0) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = v2NormalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    private nonisolated func v2BrowserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        browserPanel: BrowserPanel
    ) -> V2CallResult {
        var data = v2BrowserNotFoundDiagnostics(surfaceId: surfaceId, browserPanel: browserPanel, selector: selector)
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message = v2BrowserControl.elementNotFoundMessage(
            selector: selector,
            matchCount: count,
            visibleCount: visibleCount
        )

        return .err(code: "not_found", message: message, data: data)
    }

    private nonisolated func v2BrowserAppendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any]
    ) {
        guard v2Bool(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": v2Bool(params, "snapshot_interactive") ?? true,
            "cursor": v2Bool(params, "snapshot_cursor") ?? false,
            "compact": v2Bool(params, "snapshot_compact") ?? true,
            "max_depth": max(0, v2Int(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = v2String(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = v2OrNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    private nonisolated func v2BrowserSelectorAction(
        params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let browserPanel = ctx.browserPanel
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            let selectorCondition = "document.querySelector(\(v2JSONLiteral(selector))) !== null"

            for attempt in 1...retryAttempts {
                switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script, useEval: false) {
                case .failure(let message):
                    return .err(code: "js_error", message: message, data: ["action": actionName, "selector": selector])
                case .success(let value):
                    if let dict = value as? [String: Any],
                       let ok = dict["ok"] as? Bool,
                       ok {
                        var payload: [String: Any] = [
                            "workspace_id": ctx.workspaceId.uuidString,
                            "surface_id": surfaceId.uuidString,
                            "action": actionName,
                            "attempts": attempt
                        ]
                        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ctx.workspaceId)
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        if let resultValue = dict["value"] {
                            payload["value"] = v2NormalizeJSValue(resultValue)
                        }
                        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &payload)
                        return .ok(payload)
                    }

                    let errorText = (value as? [String: Any])?["error"] as? String
                    if errorText == "not_found", attempt < retryAttempts {
                        let waitTimeoutMs = max(80, (retryAttempts - attempt) * 80)
                        guard case .met = v2WaitForBrowserCondition(
                            ctx.webView,
                            surfaceId: surfaceId,
                            conditionScript: selectorCondition,
                            timeoutMs: waitTimeoutMs
                        ) else {
                            return v2BrowserElementNotFoundResult(
                                actionName: actionName,
                                selector: selector,
                                attempts: attempt,
                                surfaceId: surfaceId,
                                browserPanel: browserPanel
                            )
                        }
                        continue
                    }
                    if errorText == "not_found" {
                        return v2BrowserElementNotFoundResult(
                            actionName: actionName,
                            selector: selector,
                            attempts: retryAttempts,
                            surfaceId: surfaceId,
                            browserPanel: browserPanel
                        )
                    }

                    return .err(code: "js_error", message: "Browser action failed", data: ["action": actionName, "selector": selector])
                }
            }

            return v2BrowserElementNotFoundResult(
                actionName: actionName,
                selector: selector,
                attempts: retryAttempts,
                surfaceId: surfaceId,
                browserPanel: browserPanel
            )
        }
    }

    private nonisolated func v2BrowserEval(params: [String: Any]) -> V2CallResult {
        guard let script = v2String(params, "script") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            var usedIsolatedWorld = false
            switch v2RunBrowserJavaScript(
                ctx.webView,
                surfaceId: ctx.surfaceId,
                script: script,
                timeout: 10.0,
                onIsolatedWorldFallback: { usedIsolatedWorld = true }
            ) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": ctx.surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: ctx.surfaceId),
                    "value": v2NormalizeJSValue(value)
                ]
                if usedIsolatedWorld {
                    // Page-world eval was blocked (typically CSP without 'unsafe-eval'); this value
                    // came from the isolated content world. It shares the DOM but cannot read
                    // page-world JS globals, so flag it instead of returning silently.
                    payload["content_world"] = "isolated"
                    payload["content_world_note"] = "Page-world eval was blocked (likely CSP without 'unsafe-eval'); value came from the isolated content world, which shares the DOM but cannot see page-world JS globals."
                }
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserSnapshot(params: [String: Any]) -> V2CallResult {
        let interactiveOnly = v2Bool(params, "interactive") ?? false
        let includeCursor = v2Bool(params, "cursor") ?? false
        let compact = v2Bool(params, "compact") ?? false
        let maxDepth = max(0, v2Int(params, "max_depth") ?? v2Int(params, "maxDepth") ?? 12)
        let scopeSelector = v2String(params, "selector")

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let interactiveLiteral = interactiveOnly ? "true" : "false"
            let cursorLiteral = includeCursor ? "true" : "false"
            let compactLiteral = compact ? "true" : "false"
            let scopeLiteral = scopeSelector.map(v2JSONLiteral) ?? "null"

            let script = """
            (() => {
              const __interactiveOnly = \(interactiveLiteral);
              const __includeCursor = \(cursorLiteral);
              const __compact = \(compactLiteral);
              const __maxDepth = \(maxDepth);
              const __scopeSelector = \(scopeLiteral);

              const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
              const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
              const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
              const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

              const __isVisible = (el) => {
                try {
                  if (!el) return false;
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  if (!style || !rect) return false;
                  if (rect.width <= 0 || rect.height <= 0) return false;
                  if (style.display === 'none' || style.visibility === 'hidden') return false;
                  if (parseFloat(style.opacity || '1') <= 0.01) return false;
                  return true;
                } catch (_) {
                  return false;
                }
              };

              const __implicitRole = (el) => {
                const tag = String(el.tagName || '').toLowerCase();
                if (tag === 'button') return 'button';
                if (tag === 'a' && el.hasAttribute('href')) return 'link';
                if (tag === 'input') {
                  const type = String(el.getAttribute('type') || 'text').toLowerCase();
                  if (type === 'checkbox') return 'checkbox';
                  if (type === 'radio') return 'radio';
                  if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
                  return 'textbox';
                }
                if (tag === 'textarea') return 'textbox';
                if (tag === 'select') return 'combobox';
                if (tag === 'summary') return 'button';
                if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
                if (tag === 'li') return 'listitem';
                return null;
              };

              const __nameFor = (el) => {
                const aria = __normalize(el.getAttribute('aria-label') || '');
                if (aria) return aria;
                const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
                if (labelledBy) {
                  const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
                  if (text) return text;
                }
                if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
                  const placeholder = __normalize(el.getAttribute('placeholder') || '');
                  if (placeholder) return placeholder;
                  const value = __normalize(el.value || '');
                  if (value) return value;
                }
                const title = __normalize(el.getAttribute('title') || '');
                if (title) return title;
                const text = __normalize(el.innerText || el.textContent || '');
                if (text) return text.slice(0, 120);
                return '';
              };

              const __cssPath = (el) => {
                if (!el || el.nodeType !== 1) return null;
                if (el.id) return '#' + CSS.escape(el.id);
                const parts = [];
                let cur = el;
                while (cur && cur.nodeType === 1) {
                  let part = String(cur.tagName || '').toLowerCase();
                  if (!part) break;
                  if (cur.id) {
                    part += '#' + CSS.escape(cur.id);
                    parts.unshift(part);
                    break;
                  }
                  const tag = part;
                  const parent = cur.parentElement;
                  if (parent) {
                    const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                    if (siblings.length > 1) {
                      const index = siblings.indexOf(cur) + 1;
                      part += `:nth-of-type(${index})`;
                    }
                  }
                  parts.unshift(part);
                  cur = cur.parentElement;
                  if (parts.length >= 6) break;
                }
                return parts.join(' > ');
              };

              const __root = (() => {
                if (__scopeSelector) {
                  return document.querySelector(__scopeSelector) || document.body || document.documentElement;
                }
                return document.body || document.documentElement;
              })();

              const __entries = [];
              const __seen = new Set();
              const __appendEntry = (el, depth, forcedRole) => {
                if (!__isVisible(el)) return;
                const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
                const role = forcedRole || explicitRole || __implicitRole(el) || '';
                if (!role) return;

                if (__interactiveOnly && !__interactiveRoles.has(role)) return;
                if (!__interactiveOnly) {
                  const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
                  if (!includeRole) return;
                  if (__compact && __structuralRoles.has(role)) {
                    const name = __nameFor(el);
                    if (!name) return;
                  }
                }

                const selector = __cssPath(el);
                if (!selector || __seen.has(selector)) return;
                __seen.add(selector);
                __entries.push({
                  selector,
                  role,
                  name: __nameFor(el),
                  depth
                });
              };

              const __walk = (node, depth) => {
                if (!node || depth > __maxDepth || node.nodeType !== 1) return;
                const el = node;
                __appendEntry(el, depth, null);
                for (const child of Array.from(el.children || [])) {
                  __walk(child, depth + 1);
                }
              };

              if (__root) {
                __walk(__root, 0);
              }

              if (__includeCursor && __root) {
                const all = Array.from(__root.querySelectorAll('*'));
                for (const el of all) {
                  if (!__isVisible(el)) continue;
                  const style = getComputedStyle(el);
                  const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
                  const hasCursorPointer = style.cursor === 'pointer';
                  const tabIndex = el.getAttribute('tabindex');
                  const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
                  if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
                  __appendEntry(el, 0, 'generic');
                  if (__entries.length >= 256) break;
                }
              }

              const body = document.body;
              const root = document.documentElement;
              return {
                title: __normalize(document.title || ''),
                url: String(location.href || ''),
                ready_state: String(document.readyState || ''),
                text: body ? String(body.innerText || '') : '',
                html: root ? String(root.outerHTML || '') : '',
                entries: __entries
              };
            })()
            """

            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script, timeout: 10.0, useEval: false) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    return .err(code: "js_error", message: "Invalid snapshot payload", data: nil)
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? Int) ?? ((entry["depth"] as? NSNumber)?.intValue ?? 0))

                    let refToken = v2BrowserAllocateElementRef(surfaceId: surfaceId, selector: selector)
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }
                let snapshotText = snapshotLines.joined(separator: "\n")

                var payload: [String: Any] = [
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "snapshot": snapshotText,
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                return .ok(payload)
            }
        }
    }

    private nonisolated func v2BrowserWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? 5_000)
        let selectorRaw = v2BrowserSelector(params)

        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                let literal = v2JSONLiteral(urlContains)
                return "String(location.href || '').includes(\(literal))"
            }
            if let textContains = v2String(params, "text_contains") {
                let literal = v2JSONLiteral(textContains)
                return "(document.body && String(document.body.innerText || '').includes(\(literal)))"
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return """
                    (() => {
                      const __state = String(document.readyState || '').toLowerCase();
                      return __state === 'interactive' || __state === 'complete';
                    })()
                    """
                }
                let literal = v2JSONLiteral(normalizedLoadState)
                return "String(document.readyState || '').toLowerCase() === \(literal)"
            }
            if let fn = v2String(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()

        var setupResult: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var webView: WKWebView?

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupResult = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupResult = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            // Route by surface_id / tab_id / pane_id / focused, matching every other
            // socket-worker browser command. The bespoke surface_id-or-focused
            // resolution this replaced ignored pane_id and tab_id, so a wait routed
            // by pane could run against the wrong webview.
            let resolvedSurface = self.v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                setupResult = error
                return
            }
            guard let surfaceId = resolvedSurface.surfaceId else {
                setupResult = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                setupResult = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            workspaceId = ws.id
            surfaceIdOut = surfaceId
            webView = browserPanel.webView
        }

        if let setupResult {
            return setupResult
        }
        guard let workspaceId, let surfaceIdOut, let webView else {
            return .err(code: "internal_error", message: "Failed to resolve browser surface", data: nil)
        }

        let conditionScript: String
        if let selectorRaw {
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let literal = v2JSONLiteral(selector)
            conditionScript = "document.querySelector(\(literal)) !== null"
        } else {
            conditionScript = conditionScriptBase
        }

        switch v2WaitForBrowserCondition(
            webView,
            surfaceId: surfaceIdOut,
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        ) {
        case .met:
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "waited": true
            ])
        case .timedOut:
            return .err(code: "timeout", message: "Condition not met before timeout", data: ["timeout_ms": timeoutMs])
        case .evaluationFailed(let message):
            return .err(
                code: "js_error",
                message: "Wait condition could not be evaluated: \(message)",
                data: [
                    "timeout_ms": timeoutMs,
                    "url": v2MainSync { webView.url?.absoluteString ?? "about:blank" },
                    "hint": "Verify the page loaded with 'cmux browser <surface> get url' before waiting"
                ]
            )
        }
    }

    private nonisolated func v2BrowserGetText(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.text") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.innerText || el.textContent || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: String(el.outerHTML || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const value = ('value' in el) ? el.value : (el.textContent || '');
              return { ok: true, value: String(value || '') };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            let attrLiteral = v2JSONLiteral(attr)
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = v2BrowserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = v2BrowserResolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = "document.querySelectorAll(\(selectorLiteral)).length"
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let count = (value as? NSNumber)?.intValue ?? 0
                return .ok([
                    "workspace_id": ctx.workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "count": count
                ])
            }
        }
    }

    private nonisolated func v2BrowserGetBox(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.box") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const r = el.getBoundingClientRect();
              return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
            })()
            """
        }
    }

    private nonisolated func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                let propLiteral = v2JSONLiteral(property)
                return """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                })()
                """
            }
            return """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              return { ok: true, value: {
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                background: style.background,
                width: style.width,
                height: style.height
              } };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
              return { ok: true, value: visible };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const enabled = !el.disabled;
              return { ok: true, value: !!enabled };
            })()
            """
        }
    }

    private nonisolated func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              const checked = ('checked' in el) ? !!el.checked : false;
              return { ok: true, value: checked };
            })()
            """
        }
    }


    /// The ``ControlBrowserNavigationReading`` seam resolver for the worker-lane
    /// `browser.navigate`/`back`/`forward`/`reload` commands (worker:
    /// ``ControlBrowserNavigationWorker``; conformer:
    /// `TerminalController+ControlBrowserNavigationReading.swift`). `internal` and
    /// co-located with the private browser state / `v2BrowserAppendPostSnapshot`
    /// the witness cannot reach. Byte-faithful fusion of the former
    /// `v2BrowserNavigate` / `v2BrowserNavSimple` bodies (resolution, navigation
    /// calls, ref computation, and post-snapshot stay here; the worker owns the
    /// `url` parse and payload shaping). Runs on the socket-worker thread.
    nonisolated func controlResolveBrowserNavigation(
        _ request: ControlBrowserNavigationRequest
    ) -> ControlBrowserNavigationResolution {
        let params = request.params.mapValues { $0.foundationObject }
        let url = request.navigateURL

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .tabManagerUnavailable
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .invalidSurfaceID
        }
        if case .navigate = request, url == nil {
            return .missingURL
        }

        var identity: (workspaceID: UUID, workspaceRef: String, surfaceRef: String, windowID: UUID?, windowRef: String?)?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let browserPanel = ws.browserPanel(for: surfaceId) else { return }
            switch request {
            case .navigate:
                if let url { browserPanel.navigateSmart(url) }
            case .back:
                browserPanel.goBack()
            case .forward:
                browserPanel.goForward()
            case .reload:
                browserPanel.reload()
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            identity = (
                workspaceID: ws.id,
                workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: ws.id),
                surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId),
                windowID: windowId,
                windowRef: windowId.map { v2EnsureHandleRef(kind: .window, uuid: $0) }
            )
        }
        guard let identity else {
            return .surfaceNotFound(surfaceID: surfaceId)
        }
        // Run the optional --snapshot-after walk on the worker thread (not inside
        // v2MainSync) so a slow accessibility-tree snapshot on a fresh surface
        // can't block SwiftUI and recreate mount deadlocks. Standalone
        // browser.snapshot already runs here; keep the post-action path identical.
        var postPayload: [String: Any] = [:]
        v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &postPayload)
        return .navigated(ControlBrowserNavigated(
            workspaceID: identity.workspaceID,
            workspaceRef: identity.workspaceRef,
            surfaceID: surfaceId,
            surfaceRef: identity.surfaceRef,
            windowID: identity.windowID,
            windowRef: identity.windowRef,
            postSnapshot: postPayload.compactMapValues { JSONValue(foundationObject: $0) }
        ))
    }

    /// Resolves one parsed `browser.find.*` request against the live browser
    /// surface for the worker-lane ``ControlBrowserQueryWorker`` (reached through
    /// the ``ControlBrowserQueryReading`` seam, conformed in
    /// `TerminalController+ControlBrowserQueryReading.swift`).
    ///
    /// `internal` and co-located with the private per-surface browser state
    /// (`v2BrowserControl`, `v2BrowserResolveSelector`, `v2BrowserAllocateElementRef`)
    /// the witness cannot reach from its own file. This is the byte-faithful
    /// fusion of the former `v2BrowserFindWithScript` / `v2BrowserFindFirst` /
    /// `v2BrowserFindLast` / `v2BrowserFindNth` bodies: the panel resolution, the
    /// finder-script construction, the JS evaluation, the result decoding, and the
    /// element-ref allocation all stay here; the worker owns the param parsing,
    /// the missing-param branches, and the reply payload shaping. Runs on the
    /// calling socket-worker thread (the JS evaluation blocks there).
    nonisolated func controlResolveBrowserFind(
        _ request: ControlBrowserFindRequest
    ) -> ControlBrowserFindResolution {
        switch request {
        case let .role(params, role, name, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findRoleFinderBody(role: role, name: name, exact: exact)
            )
        case let .text(params, text, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findTextFinderBody(text: text, exact: exact)
            )
        case let .label(params, label, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findLabelFinderBody(label: label, exact: exact)
            )
        case let .placeholder(params, placeholder, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findPlaceholderFinderBody(placeholder: placeholder, exact: exact)
            )
        case let .alt(params, alt, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findAltFinderBody(alt: alt, exact: exact)
            )
        case let .title(params, title, exact):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findTitleFinderBody(title: title, exact: exact)
            )
        case let .testID(params, testID):
            return v2ControlFindWithScript(
                foundationParams(params),
                finderBody: v2BrowserControl.findTestIdFinderBody(testId: testID)
            )
        case let .first(params, rawSelector):
            return v2ControlFindFirst(foundationParams(params), rawSelector: rawSelector)
        case let .last(params, rawSelector):
            return v2ControlFindLast(foundationParams(params), rawSelector: rawSelector)
        case let .nth(params, rawSelector, index):
            return v2ControlFindNth(foundationParams(params), rawSelector: rawSelector, index: index)
        }
    }

    /// Resolves one `browser.get.*` / `browser.is.*` query request by running the
    /// co-located legacy getter body and carrying its `V2CallResult` pre-shaped.
    ///
    /// Byte-faithful to the former `v2BrowserJSCommandOnSocketWorker` dispatch for
    /// these methods: each case calls the identical `v2BrowserGet*` / `v2BrowserIs*`
    /// body with the Foundation-bridged params, and `controlBridge` maps the
    /// resulting payload to the package's typed `ControlCallResult`. The getter
    /// bodies stay app-side because they reach the shared `v2BrowserSelectorAction`
    /// retry loop (still shared with the `browser.*` interaction commands), the
    /// `v2BrowserWithPanel` panel read (`get.title`), the `v2BrowserWithPanelContext`
    /// `querySelectorAll` read (`get.count`), and the WebKit evaluation seam, none of
    /// which this control package may import.
    ///
    /// `get.attr` re-reads and re-validates `attr`/`name` inside `v2BrowserGetAttr`
    /// identically to the worker's guard, so passing the validated request straight
    /// through preserves the legacy missing-param branch exactly (the worker's guard
    /// and the body's guard are the same trimmed-non-empty check).
    nonisolated func controlResolveBrowserQuery(
        _ request: ControlBrowserQueryActionRequest
    ) -> ControlCallResult {
        switch request {
        case let .getText(params):
            return controlBridge(v2BrowserGetText(params: foundationParams(params)))
        case let .getHTML(params):
            return controlBridge(v2BrowserGetHTML(params: foundationParams(params)))
        case let .getValue(params):
            return controlBridge(v2BrowserGetValue(params: foundationParams(params)))
        case let .getAttr(params, _):
            return controlBridge(v2BrowserGetAttr(params: foundationParams(params)))
        case let .getCount(params):
            return controlBridge(v2BrowserGetCount(params: foundationParams(params)))
        case let .getBox(params):
            return controlBridge(v2BrowserGetBox(params: foundationParams(params)))
        case let .getStyles(params):
            return controlBridge(v2BrowserGetStyles(params: foundationParams(params)))
        case let .isVisible(params):
            return controlBridge(v2BrowserIsVisible(params: foundationParams(params)))
        case let .isEnabled(params):
            return controlBridge(v2BrowserIsEnabled(params: foundationParams(params)))
        case let .isChecked(params):
            return controlBridge(v2BrowserIsChecked(params: foundationParams(params)))
        }
    }

    /// Bridges a typed `[String: JSONValue]` param object back to the Foundation
    /// `[String: Any]` the legacy panel-resolution head (`v2ResolveTabManager` /
    /// `v2ResolveWorkspace` / `v2ResolveBrowserSurfaceId`) reads. The worker
    /// re-derives the leaf params (selector/role/text/…) it needs typed; this
    /// carries the routing selectors verbatim.
    private nonisolated func foundationParams(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues { $0.foundationObject }
    }

    /// The byte-faithful `v2BrowserFindWithScript` body, returning the typed
    /// resolution instead of a wire payload.
    private nonisolated func v2ControlFindWithScript(
        _ params: [String: Any],
        finderBody: String
    ) -> ControlBrowserFindResolution {
        v2ControlResolveOnPanel(params) { ctx in
            let script = v2BrowserControl.findScript(finderBody: finderBody)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    return .notFound(data: nil)
                }
                return v2ControlFound(
                    ctx,
                    selector: selector,
                    tag: dict["tag"] as? String,
                    text: (dict["text"] as? String).map { .string($0) } ?? .omitted,
                    index: nil
                )
            }
        }
    }

    /// The byte-faithful `v2BrowserFindFirst` body.
    private nonisolated func v2ControlFindFirst(
        _ params: [String: Any],
        rawSelector: String
    ) -> ControlBrowserFindResolution {
        v2ControlResolveSelectorOnPanel(params, rawSelector: rawSelector) { ctx, selector in
            let script = v2BrowserControl.findFirstScript(selector: selector)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .notFound(data: ["selector": .string(selector)])
                }
                return v2ControlFound(
                    ctx,
                    selector: selector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: nil
                )
            }
        }
    }

    /// The byte-faithful `v2BrowserFindLast` body.
    private nonisolated func v2ControlFindLast(
        _ params: [String: Any],
        rawSelector: String
    ) -> ControlBrowserFindResolution {
        v2ControlResolveSelectorOnPanel(params, rawSelector: rawSelector) { ctx, selector in
            let script = v2BrowserControl.findLastScript(selector: selector)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .notFound(data: ["selector": .string(selector)])
                }
                return v2ControlFound(
                    ctx,
                    selector: finalSelector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: nil
                )
            }
        }
    }

    /// The byte-faithful `v2BrowserFindNth` body.
    private nonisolated func v2ControlFindNth(
        _ params: [String: Any],
        rawSelector: String,
        index: Int
    ) -> ControlBrowserFindResolution {
        v2ControlResolveSelectorOnPanel(params, rawSelector: rawSelector) { ctx, selector in
            let script = v2BrowserControl.findNthScript(selector: selector, index: index)
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: ctx.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    return .notFound(data: [
                        "selector": .string(selector),
                        "index": .int(Int64(index))
                    ])
                }
                return v2ControlFound(
                    ctx,
                    selector: finalSelector,
                    tag: nil,
                    text: .orNull(dict["text"] as? String),
                    index: .orNull((dict["index"] as? NSNumber)?.intValue ?? dict["index"] as? Int)
                )
            }
        }
    }

    /// Resolves the browser panel (the shared `v2BrowserWithPanelContext` head)
    /// and runs `body` on it, translating a panel-head failure into
    /// `.panelUnavailable`. `body` returns the typed resolution directly.
    private nonisolated func v2ControlResolveOnPanel(
        _ params: [String: Any],
        _ body: (_ ctx: V2BrowserPanelContext) -> ControlBrowserFindResolution
    ) -> ControlBrowserFindResolution {
        var resolution: ControlBrowserFindResolution = .notFound(data: nil)
        let panelResult = v2BrowserWithPanelContext(params: params) { ctx in
            resolution = body(ctx)
            return .ok(NSNull())
        }
        if case let .err(code, message, data) = panelResult {
            return .panelUnavailable(.err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) }))
        }
        return resolution
    }

    /// `v2ControlResolveOnPanel` plus the shared `v2BrowserResolveSelector` step
    /// (the first/last/nth "Element reference not found" branch).
    private nonisolated func v2ControlResolveSelectorOnPanel(
        _ params: [String: Any],
        rawSelector: String,
        _ body: (_ ctx: V2BrowserPanelContext, _ selector: String) -> ControlBrowserFindResolution
    ) -> ControlBrowserFindResolution {
        v2ControlResolveOnPanel(params) { ctx in
            guard let selector = v2BrowserResolveSelector(rawSelector, surfaceId: ctx.surfaceId) else {
                return .selectorReferenceNotFound(rawSelector: rawSelector)
            }
            return body(ctx, selector)
        }
    }

    /// Builds a `.found` resolution from a resolved panel context, allocating the
    /// element ref against `selector` and computing the workspace/surface refs
    /// (the shared tail of every find body).
    private nonisolated func v2ControlFound(
        _ ctx: V2BrowserPanelContext,
        selector: String,
        tag: String?,
        text: ControlBrowserFindResultText,
        index: ControlBrowserFindResultIndex?
    ) -> ControlBrowserFindResolution {
        let ref = v2BrowserAllocateElementRef(surfaceId: ctx.surfaceId, selector: selector)
        return .found(ControlBrowserFoundElement(
            workspaceID: ctx.workspaceId,
            workspaceRef: (v2Ref(kind: .workspace, uuid: ctx.workspaceId) as? String) ?? ctx.workspaceId.uuidString,
            surfaceID: ctx.surfaceId,
            surfaceRef: (v2Ref(kind: .surface, uuid: ctx.surfaceId) as? String) ?? ctx.surfaceId.uuidString,
            selector: selector,
            elementRef: ref,
            tag: tag,
            text: text,
            index: index
        ))
    }

    /// The ``ControlBrowserInteractionReading`` seam resolver for the worker-lane
    /// `browser.*` interaction commands (worker:
    /// ``ControlBrowserInteractionWorker``; conformer:
    /// `TerminalController+ControlBrowserInteractionReading.swift`). `internal` and
    /// co-located with the private per-surface browser state the witness cannot
    /// reach. Byte-faithful fusion of the former `v2BrowserClick` … `v2BrowserScroll`
    /// bodies: panel resolution, the per-action `BrowserControlService` script
    /// construction, the shared `v2BrowserSelectorAction` retry loop (still shared
    /// with the not-yet-extracted `browser.get.*` / `browser.is.*` query commands,
    /// so its payload is carried pre-shaped), the JS eval, the not-found
    /// diagnostics, and the post-snapshot stay here; the worker owns the leaf-param
    /// parsing and the panel-action payload shaping. Runs on the socket-worker
    /// thread.
    nonisolated func controlResolveBrowserInteraction(
        _ request: ControlBrowserInteractionRequest
    ) -> ControlBrowserInteractionResolution {
        switch request {
        case let .click(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "click") { selectorLiteral in
                v2BrowserControl.clickScript(selectorLiteral: selectorLiteral)
            }
        case let .doubleClick(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "dblclick") { selectorLiteral in
                v2BrowserControl.doubleClickScript(selectorLiteral: selectorLiteral)
            }
        case let .hover(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "hover") { selectorLiteral in
                v2BrowserControl.hoverScript(selectorLiteral: selectorLiteral)
            }
        case let .focusElement(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "focus") { selectorLiteral in
                v2BrowserControl.focusElementScript(selectorLiteral: selectorLiteral)
            }
        case let .type(params, text):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "type") { selectorLiteral in
                v2BrowserControl.typeScript(selectorLiteral: selectorLiteral, textLiteral: v2JSONLiteral(text))
            }
        case let .fill(params, text):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "fill") { selectorLiteral in
                v2BrowserControl.fillScript(selectorLiteral: selectorLiteral, textLiteral: v2JSONLiteral(text))
            }
        case let .check(params, checked):
            return controlBridgeSelectorAction(foundationParams(params), actionName: checked ? "check" : "uncheck") { selectorLiteral in
                v2BrowserControl.setCheckedScript(selectorLiteral: selectorLiteral, checked: checked)
            }
        case let .selectOption(params, value):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "select") { selectorLiteral in
                v2BrowserControl.selectOptionScript(selectorLiteral: selectorLiteral, valueLiteral: v2JSONLiteral(value))
            }
        case let .scrollIntoView(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "scroll_into_view") { selectorLiteral in
                v2BrowserControl.scrollIntoViewScript(selectorLiteral: selectorLiteral)
            }
        case let .highlight(params):
            return controlBridgeSelectorAction(foundationParams(params), actionName: "highlight") { selectorLiteral in
                """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  const prev = el.style.outline;
                  const prevOffset = el.style.outlineOffset;
                  el.style.outline = '3px solid #ff9f0a';
                  el.style.outlineOffset = '2px';
                  setTimeout(() => {
                    el.style.outline = prev;
                    el.style.outlineOffset = prevOffset;
                  }, 1200);
                  return { ok: true };
                })()
                """
            }
        case let .press(params, key):
            return controlResolveBrowserKeyEvent(foundationParams(params), script: v2BrowserControl.pressScript(keyLiteral: v2JSONLiteral(key)))
        case let .keyDown(params, key):
            return controlResolveBrowserKeyEvent(foundationParams(params), script: v2BrowserControl.keyDownScript(keyLiteral: v2JSONLiteral(key)))
        case let .keyUp(params, key):
            return controlResolveBrowserKeyEvent(foundationParams(params), script: v2BrowserControl.keyUpScript(keyLiteral: v2JSONLiteral(key)))
        case let .scroll(params, dx, dy):
            return controlResolveBrowserScroll(foundationParams(params), dx: dx, dy: dy)
        }
    }

    /// Runs the shared `v2BrowserSelectorAction` retry body for one selector-action
    /// interaction and carries its `V2CallResult` payload pre-shaped (including the
    /// shared body's own missing-selector `invalid_params` branch).
    private nonisolated func controlBridgeSelectorAction(
        _ params: [String: Any],
        actionName: String,
        scriptBuilder: (_ selectorLiteral: String) -> String
    ) -> ControlBrowserInteractionResolution {
        .preShaped(controlBridge(v2BrowserSelectorAction(params: params, actionName: actionName, scriptBuilder: scriptBuilder)))
    }

    /// The byte-faithful `v2BrowserPress` / `v2BrowserKeyDown` / `v2BrowserKeyUp`
    /// body (they differ only by the script). The panel-head and JS failures travel
    /// as the returned `V2CallResult` (carried pre-shaped); the success is captured
    /// out through a `var` as a `.panelAction` the worker shapes (the head's
    /// sentinel `.ok` is ignored), matching the legacy branch structure exactly.
    private nonisolated func controlResolveBrowserKeyEvent(
        _ params: [String: Any],
        script: String
    ) -> ControlBrowserInteractionResolution {
        var success: ControlBrowserPanelActionSuccess?
        let panelResult = v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success:
                var postPayload: [String: Any] = [:]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &postPayload)
                success = ControlBrowserPanelActionSuccess(
                    workspaceID: ctx.workspaceId,
                    workspaceRef: (v2Ref(kind: .workspace, uuid: ctx.workspaceId) as? String) ?? ctx.workspaceId.uuidString,
                    surfaceID: surfaceId,
                    surfaceRef: (v2Ref(kind: .surface, uuid: surfaceId) as? String) ?? surfaceId.uuidString,
                    postSnapshot: postPayload.compactMapValues { JSONValue(foundationObject: $0) }
                )
                return .ok(NSNull())
            }
        }
        if let success {
            return .panelAction(success)
        }
        return .preShaped(controlBridge(panelResult))
    }

    /// The byte-faithful `v2BrowserScroll` body. The panel-head/ref-not-found/JS/
    /// not-found-diagnostics branches are carried pre-shaped (they reuse shared
    /// app-side helpers); the window-vs-element success is a `.panelAction` the
    /// worker shapes, captured out through a `var` like `controlResolveBrowserKeyEvent`.
    private nonisolated func controlResolveBrowserScroll(
        _ params: [String: Any],
        dx: Int,
        dy: Int
    ) -> ControlBrowserInteractionResolution {
        let selectorRaw = v2BrowserSelector(params)

        var success: ControlBrowserPanelActionSuccess?
        let panelResult = v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let selector = selectorRaw.flatMap { v2BrowserResolveSelector($0, surfaceId: surfaceId) }
            if selectorRaw != nil && selector == nil {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw ?? ""])
            }

            let script: String
            if let selector {
                script = v2BrowserControl.scrollElementScript(selectorLiteral: v2JSONLiteral(selector), dx: dx, dy: dy)
            } else {
                script = v2BrowserControl.scrollWindowScript(dx: dx, dy: dy)
            }

            switch v2RunBrowserJavaScript(ctx.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   !ok,
                   let errorText = dict["error"] as? String,
                   errorText == "not_found" {
                    if let selector {
                        return v2BrowserElementNotFoundResult(
                            actionName: "scroll",
                            selector: selector,
                            attempts: 1,
                            surfaceId: surfaceId,
                            browserPanel: ctx.browserPanel
                        )
                    }
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                var postPayload: [String: Any] = [:]
                v2BrowserAppendPostSnapshot(params: params, surfaceId: surfaceId, payload: &postPayload)
                success = ControlBrowserPanelActionSuccess(
                    workspaceID: ctx.workspaceId,
                    workspaceRef: (v2Ref(kind: .workspace, uuid: ctx.workspaceId) as? String) ?? ctx.workspaceId.uuidString,
                    surfaceID: surfaceId,
                    surfaceRef: (v2Ref(kind: .surface, uuid: surfaceId) as? String) ?? surfaceId.uuidString,
                    postSnapshot: postPayload.compactMapValues { JSONValue(foundationObject: $0) }
                )
                return .ok(NSNull())
            }
        }
        if let success {
            return .panelAction(success)
        }
        return .preShaped(controlBridge(panelResult))
    }

    /// Bridges an app-side `V2CallResult` to the package's typed `ControlCallResult`,
    /// byte-faithful for any payload `JSONSerialization` accepts (these payloads are
    /// dictionaries of strings/ints/bools and already-normalized JS values, so the
    /// unencodable `.ok({})` fallback is unreachable — the same documented delta as
    /// the surface.move / mobile passthroughs vs the legacy `v2Ok`).
    private nonisolated func controlBridge(_ result: V2CallResult) -> ControlCallResult {
        switch result {
        case .ok(let payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // `internal` (not `private`): the browser console/errors witnesses in
    // `TerminalController+ControlBrowserConsoleErrorsStateContext.swift` install
    // the telemetry hooks before reading the console/error rings, matching the
    // cookies/storage cross-file witness pattern.
    func v2BrowserEnsureTelemetryHooks(surfaceId _: UUID, browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.telemetryHookBootstrapScriptSource,
            timeout: 5.0,
            world: .page
        )
    }

    private func v2BrowserEnsureDialogHooks(browserPanel: BrowserPanel) {
        _ = v2RunJavaScript(
            browserPanel.webView,
            script: BrowserPanel.dialogTelemetryHookBootstrapScriptSource,
            timeout: 5.0,
            world: .page
        )
    }

    /// `browser.dialog.accept` / `browser.dialog.dismiss` witness
    /// (``ControlBrowserContext``): shifts the front entry off the resolved
    /// browser's in-page dialog queue and records the chosen default,
    /// byte-faithful to the former `v2BrowserDialogRespond(params:accept:)` body.
    /// The coordinator owns the `accepted` payload key (the `accept` arg) and the
    /// `text`/`prompt_text` fallback. Stays on `TerminalController` because it
    /// calls the `private` dialog-hook + pending-dialog plumbing
    /// (`v2BrowserEnsureDialogHooks`, `v2BrowserPendingDialogs`).
    func controlBrowserDialogRespond(
        params: [String: JSONValue],
        accept: Bool,
        text: String?
    ) -> ControlBrowserDialogRespondResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let surfaceId = resolved.surfaceId
            let browserPanel = resolved.browserPanel
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            v2BrowserEnsureDialogHooks(browserPanel: browserPanel)
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__cmuxDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__cmuxDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__cmuxDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                        .compactMap { JSONValue(foundationObject: $0) }
                    return .notFound(pending: pending)
                }

                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: surfaceId,
                    dialog: JSONValue(foundationObject: v2NormalizeJSValue(dict["dialog"])) ?? .null,
                    remaining: JSONValue(foundationObject: v2OrNull(dict["remaining"])) ?? .null
                )
            }
        }
    }

    /// `browser.get.title` witness (``ControlBrowserContext``): reads the
    /// resolved browser panel's `pageTitle`, byte-faithful to the former
    /// `v2BrowserGetTitle(params:)` body. The coordinator owns the identity
    /// payload + `title` key. Stays on `TerminalController` because it shares the
    /// `private` `v2BrowserWithPanel`-head plumbing through
    /// `browserResolvePanelTyped`.
    func controlBrowserGetTitle(
        params: [String: JSONValue]
    ) -> ControlBrowserGetTitleResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                title: resolved.browserPanel.pageTitle
            )
        }
    }

    /// `browser.frame.select` witness (``ControlBrowserContext``): resolves the
    /// (possibly `@e`-ref) selector against the surface, evaluates the
    /// same-origin iframe probe, and on success records the per-surface frame
    /// selector, byte-faithful to the former `v2BrowserFrameSelect(params:)`
    /// body. The coordinator owns the `Missing selector` guard, the identity
    /// payload, and the `frame_selector` key. Stays on `TerminalController`
    /// because it mutates the `private` `v2BrowserFrameSelectorBySurface` cache
    /// (read by the out-of-scope worker-lane JS-eval methods).
    func controlBrowserFrameSelect(
        params: [String: JSONValue],
        rawSelector: String
    ) -> ControlBrowserFrameSelectResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let surfaceId = resolved.surfaceId
            let browserPanel = resolved.browserPanel
            guard let selector = v2BrowserResolveSelector(rawSelector, surfaceId: surfaceId) else {
                return .elementRefNotFound(rawSelector: rawSelector)
            }
            let selectorLiteral = v2JSONLiteral(selector)
            let script = """
            (() => {
              const frame = document.querySelector(\(selectorLiteral));
              if (!frame) return { ok: false, error: 'not_found' };
              if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
              try {
                const sameOrigin = !!frame.contentDocument;
                if (!sameOrigin) return { ok: false, error: 'cross_origin' };
              } catch (_) {
                return { ok: false, error: 'cross_origin' };
              }
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserFrameSelectorBySurface[surfaceId] = selector
                    return .selected(
                        workspaceID: resolved.workspace.id,
                        surfaceID: surfaceId,
                        frameSelector: selector
                    )
                }
                if let dict = value as? [String: Any],
                   let errorText = dict["error"] as? String,
                   errorText == "cross_origin" {
                    return .crossOrigin(selector: selector)
                }
                return .frameNotFound(selector: selector)
            }
        }
    }

    /// `browser.frame.main` witness (``ControlBrowserContext``): clears the
    /// per-surface pinned frame selector, byte-faithful to the former
    /// `v2BrowserFrameMain(params:)` body. The coordinator owns the identity
    /// payload + the JSON-null `frame_selector`. Stays on `TerminalController`
    /// because it mutates the `private` `v2BrowserFrameSelectorBySurface` cache.
    func controlBrowserFrameMain(
        params: [String: JSONValue]
    ) -> ControlBrowserFrameMainResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            v2BrowserFrameSelectorBySurface.removeValue(forKey: resolved.surfaceId)
            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId
            )
        }
    }

    /// `browser.screenshot` witness (``ControlBrowserContext``): captures the
    /// resolved browser's automation-visible viewport snapshot (15s budget),
    /// PNG-encodes it, and best-effort writes a pruned temp file, byte-faithful
    /// to the former `v2BrowserScreenshot(params:)` body. The coordinator owns
    /// the identity payload + `png_base64`/`path`/`url` keys. Stays on
    /// `TerminalController` because it calls the `private`
    /// `v2AwaitCallback`/`v2PNGData`/`bestEffortPruneTemporaryFiles` plumbing
    /// and `BrowserPanel.captureAutomationVisibleViewportSnapshot`.
    func controlBrowserScreenshot(
        params: [String: JSONValue]
    ) -> ControlBrowserScreenshotResolution {
        let resolved: ResolvedBrowserPanel
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let value):
            resolved = value
        }
        let surfaceId = resolved.surfaceId
        let browserPanel = resolved.browserPanel

        let snapshotResult: Data?? = v2AwaitCallback(timeout: 15.0) { finish in
            browserPanel.captureAutomationVisibleViewportSnapshot { result in
                switch result {
                case .success(let image):
                    finish(self.v2PNGData(from: image))
                case .failure:
                    finish(nil)
                }
            }
        }

        guard let snapshotResult else {
            return .timedOut
        }
        guard let imageData = snapshotResult else {
            return .captureFailed
        }

        let pngBase64 = imageData.base64EncodedString()

        // Best effort: keep screenshot data available even when temp-file writes fail.
        var filePath: String?
        var fileURL: String?
        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let filename = "surface-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).png"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? imageData.write(to: imageURL, options: .atomic)) != nil {
                filePath = imageURL.path
                fileURL = imageURL.absoluteString
            }
        }

        return .resolved(
            workspaceID: resolved.workspace.id,
            surfaceID: surfaceId,
            pngBase64: pngBase64,
            filePath: filePath,
            fileURL: fileURL
        )
    }

    private struct V2BrowserDownloadWaitSnapshot {
        let workspaceId: UUID
        let workspaceRef: Any
        let surfaceId: UUID
        let surfaceRef: Any
        let queuedEvent: [String: Any]?
        let error: V2CallResult?
    }

    private enum V2DownloadFileWaitResult: Sendable {
        case ready
        case timeout
        case watcherSetupFailed(errnoCode: Int32)
    }

    /// Socket-worker router for browser methods that evaluate page JavaScript.
    /// See ControlCommandExecutionPolicy for why these must not hold the main actor.
    private nonisolated func v2BrowserJSCommandOnSocketWorker(method: String, params: [String: Any]) -> V2CallResult {
        switch method {
        case "browser.snapshot": return v2BrowserSnapshot(params: params)
        case "browser.eval": return v2BrowserEval(params: params)
        case "browser.wait": return v2BrowserWait(params: params)
        default:
            return .err(code: "invalid_dispatch", message: "Unhandled socket-worker browser method \(method)", data: nil)
        }
    }

    private nonisolated func v2BrowserDownloadWaitOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let requestedTimeoutMs = max(
            1,
            Self.v2WorkerInt(params, "timeout_ms") ??
                Self.v2WorkerInt(params, "timeout") ??
                Self.v2BrowserDownloadWaitDefaultTimeoutMs
        )
        let timeoutMs = min(requestedTimeoutMs, Self.v2BrowserDownloadWaitMaxTimeoutMs)
        let timeout = Double(timeoutMs) / 1000.0
        let path = Self.v2WorkerString(params, "path")

        let snapshot = v2BrowserDownloadWaitSnapshot(params: params)
        if let error = snapshot.error {
            return error
        }

        if let path {
            switch v2WaitForDownloadFile(path: path, timeout: timeout) {
            case .ready:
                break
            case .timeout:
                return .err(
                    code: "timeout",
                    message: "Timed out waiting for download file",
                    data: [
                        "path": path,
                        "timeout_ms": timeoutMs,
                        "requested_timeout_ms": requestedTimeoutMs
                    ]
                )
            case .watcherSetupFailed(let errnoCode):
                return .err(
                    code: "internal_error",
                    message: "Failed to watch download path",
                    data: ["path": path, "errno": Int(errnoCode)]
                )
            }
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "path": path,
                "downloaded": true
            ])
        }

        if let queuedEvent = snapshot.queuedEvent {
            return .ok([
                "workspace_id": snapshot.workspaceId.uuidString,
                "workspace_ref": snapshot.workspaceRef,
                "surface_id": snapshot.surfaceId.uuidString,
                "surface_ref": snapshot.surfaceRef,
                "download": queuedEvent
            ])
        }

        guard let downloadEvent = v2WaitForDownloadEvent(surfaceId: snapshot.surfaceId, timeout: timeout) else {
            return .err(
                code: "timeout",
                message: "No download event observed",
                data: [
                    "timeout_ms": timeoutMs,
                    "requested_timeout_ms": requestedTimeoutMs
                ]
            )
        }
        return .ok([
            "workspace_id": snapshot.workspaceId.uuidString,
            "workspace_ref": snapshot.workspaceRef,
            "surface_id": snapshot.surfaceId.uuidString,
            "surface_ref": snapshot.surfaceRef,
            "download": downloadEvent
        ])
    }

    private nonisolated static func v2WorkerString(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func v2WorkerInt(_ params: [String: Any], _ key: String) -> Int? {
        if let intValue = params[key] as? Int {
            return intValue
        }
        if let number = params[key] as? NSNumber {
            return number.intValue
        }
        if let raw = v2WorkerString(params, key) {
            return Int(raw)
        }
        return nil
    }

    private nonisolated func v2BrowserDownloadWaitSnapshot(params: [String: Any]) -> V2BrowserDownloadWaitSnapshot {
        v2MainSync {
            v2RefreshKnownRefs()
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "unavailable", message: "TabManager not available", data: nil)
                )
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: UUID(),
                    workspaceRef: NSNull(),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "not_found", message: "Workspace not found", data: nil)
                )
            }
            let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: error
                )
            }
            let surfaceId = resolvedSurface.surfaceId
            guard let surfaceId else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: UUID(),
                    surfaceRef: NSNull(),
                    queuedEvent: nil,
                    error: .err(code: "not_found", message: "No focused browser surface", data: nil)
                )
            }
            guard ws.browserPanel(for: surfaceId) != nil else {
                return V2BrowserDownloadWaitSnapshot(
                    workspaceId: ws.id,
                    workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                    surfaceId: surfaceId,
                    surfaceRef: v2Ref(kind: .surface, uuid: surfaceId),
                    queuedEvent: nil,
                    error: .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                )
            }

            return V2BrowserDownloadWaitSnapshot(
                workspaceId: ws.id,
                workspaceRef: v2Ref(kind: .workspace, uuid: ws.id),
                surfaceId: surfaceId,
                surfaceRef: v2Ref(kind: .surface, uuid: surfaceId),
                queuedEvent: Self.v2WorkerString(params, "path") == nil
                    ? v2PopBrowserDownloadEvent(surfaceId: surfaceId)
                    : nil,
                error: nil
            )
        }
    }

    private func v2PopBrowserDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        guard let first = v2BrowserDownloadEventsBySurface[surfaceId]?.first else {
            return nil
        }
        var remaining = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
        remaining.removeFirst()
        v2BrowserDownloadEventsBySurface[surfaceId] = remaining
        return first
    }

    private nonisolated func v2WaitForDownloadFile(path: String, timeout: TimeInterval) -> V2DownloadFileWaitResult {
        let fm = FileManager.default
        let pathIsReady = {
            guard fm.fileExists(atPath: path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }
        if pathIsReady() {
            return .ready
        }

        let watchedPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(watchedPath, O_EVTONLY)
        guard fd >= 0 else {
            return .watcherSetupFailed(errnoCode: errno)
        }

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var ready = false
        let finishOnce: (Bool) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            ready = value
            lock.unlock()
            semaphore.signal()
        }

        let watcherQueue = DispatchQueue(label: "com.cmux.browser.download.wait.file")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename],
            queue: watcherQueue
        )
        source.setEventHandler {
            if pathIsReady() {
                finishOnce(true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        if pathIsReady() {
            finishOnce(true)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(pathIsReady())
        }
        source.cancel()
        return ready ? .ready : .timeout
    }

    private nonisolated func v2WaitForDownloadEvent(surfaceId: UUID, timeout: TimeInterval) -> [String: Any]? {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var event: [String: Any]?
        var observer: NSObjectProtocol?

        let finishOnce: ([String: Any]?) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            event = value
            lock.unlock()
            semaphore.signal()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .browserDownloadEventDidArrive,
            object: nil,
            queue: nil
        ) { note in
            guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  candidateSurfaceId == surfaceId,
                  let event = note.userInfo?["event"] as? [String: Any] else {
                return
            }
            finishOnce(event)
        }

        if let queued = v2MainSync({ v2PopBrowserDownloadEvent(surfaceId: surfaceId) }) {
            finishOnce(queued)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(nil)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return event
    }

    /// `browser.import.dialog` witness (``ControlBrowserContext``): validates the
    /// `scope` / `destination_profile` params and schedules the browser
    /// data-import dialog presentation, byte-faithful to the former
    /// `v2BrowserImportDialog(params:)` body. The coordinator re-emits each typed
    /// failure category as the exact legacy `invalid_params` error. Stays on
    /// `TerminalController` purely for co-location with the rest of the moved
    /// browser-dialog domain (it reaches only app-wide singletons, no `private`
    /// `TerminalController` state).
    func controlBrowserImportDialog(
        params: [String: JSONValue]
    ) -> ControlBrowserImportDialogResolution {
        let foundation = params.mapValues(\.foundationObject)
        let scope: BrowserImportScope?
        if foundation.keys.contains("scope") {
            guard let raw = v2String(foundation, "scope")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else {
                return .scopeEmpty
            }
            switch raw {
            case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
                scope = .cookiesOnly
            case "history", "historyonly", "history_only", "history-only":
                scope = .historyOnly
            case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
                scope = .cookiesAndHistory
            case "everything", "all":
                scope = .everything
            default:
                return .scopeInvalid
            }
        } else {
            scope = nil
        }

        let defaultDestinationProfileID: UUID?
        if foundation.keys.contains("destination_profile") {
            guard let query = v2String(foundation, "destination_profile")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return .destinationProfileEmpty
            }
            let profiles = BrowserProfileStore.shared.profiles
            if let uuid = UUID(uuidString: query),
               profiles.contains(where: { $0.id == uuid }) {
                defaultDestinationProfileID = uuid
            } else if let profile = profiles.first(where: {
                $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                    $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                defaultDestinationProfileID = profile.id
            } else if v2Bool(foundation, "create_destination_profile") == true ||
                v2Bool(foundation, "create_profile") == true {
                guard let createdProfileID = BrowserProfileStore.shared.createProfile(named: query)?.id else {
                    return .destinationProfileCreateFailed
                }
                defaultDestinationProfileID = createdProfileID
            } else {
                return .destinationProfileNoMatch
            }
        } else {
            defaultDestinationProfileID = nil
        }
        Task { @MainActor in
            BrowserDataImportCoordinator.shared.presentImportDialog(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: scope
            )
        }
        return .opened(scopeRawValue: scope?.rawValue)
    }

    // `internal` (not `private`): the browser state.save witness in
    // `TerminalController+ControlBrowserConsoleErrorsStateContext.swift` encodes
    // each saved cookie as its byte-identical wire dictionary through this helper,
    // matching the cookies/storage cross-file witness pattern.
    func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }


    func v2BrowserStorageType(_ params: [String: Any]) -> String {
        v2BrowserControl.storageType(params: params)
    }


    /// `browser.addinitscript` witness (``ControlBrowserContext``): registers a
    /// document-start init script on the resolved browser and evaluates it once,
    /// byte-faithful to the former `v2BrowserAddInitScript(params:)` body. The
    /// coordinator emits the `Missing script` param error before this runs and
    /// shapes the identity payload plus `scripts` count. Stays on
    /// `TerminalController` (not the cookies/storage context file) because it
    /// mutates the `private` per-surface `v2BrowserInitScriptsBySurface` cache,
    /// which the surface-teardown cleanup also reaches.
    func controlBrowserAddInitScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddInitScriptResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            var scripts = v2BrowserInitScriptsBySurface[resolved.surfaceId] ?? []
            scripts.append(script)
            v2BrowserInitScriptsBySurface[resolved.surfaceId] = scripts

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            resolved.browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script, timeout: 10.0)

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                scriptCount: scripts.count
            )
        }
    }

    /// `browser.addscript` witness (``ControlBrowserContext``): evaluates a
    /// one-shot script on the resolved browser, byte-faithful to the former
    /// `v2BrowserAddScript(params:)` body. The coordinator emits the
    /// `Missing script` param error before this runs and shapes the identity
    /// payload plus the normalized `value`.
    func controlBrowserAddScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddScriptResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            switch v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script, timeout: 10.0) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    value: JSONValue(foundationObject: v2NormalizeJSValue(value)) ?? .null
                )
            }
        }
    }

    /// `browser.addstyle` witness (``ControlBrowserContext``): registers a
    /// document-start `<style>`-injecting init script on the resolved browser and
    /// evaluates it once, byte-faithful to the former `v2BrowserAddStyle(params:)`
    /// body. The coordinator emits the `Missing css/style content` param error
    /// before this runs and shapes the identity payload plus `styles` count.
    /// Stays on `TerminalController` because it mutates the `private` per-surface
    /// `v2BrowserInitStylesBySurface` cache, which surface teardown also reaches.
    func controlBrowserAddStyle(
        params: [String: JSONValue],
        css: String
    ) -> ControlBrowserAddStyleResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            var styles = v2BrowserInitStylesBySurface[resolved.surfaceId] ?? []
            styles.append(css)
            v2BrowserInitStylesBySurface[resolved.surfaceId] = styles

            let cssLiteral = v2JSONLiteral(css)
            let source = """
            (() => {
              const el = document.createElement('style');
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            resolved.browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: source, timeout: 10.0)

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                styleCount: styles.count
            )
        }
    }

    // browser.viewport.set / browser.geolocation.set / browser.offline.set /
    // browser.trace.start / browser.trace.stop / browser.network.route /
    // browser.network.unroute / browser.network.requests /
    // browser.screencast.start / browser.screencast.stop / browser.input_mouse /
    // browser.input_keyboard / browser.input_touch moved to
    // ControlCommandCoordinator.handleBrowserUnsupported (CmuxControlSocket).
    // The per-surface unsupported-network-request log stays here
    // (v2BrowserUnsupportedNetworkRequestsBySurface, cleared on surface
    // teardown); the coordinator records into / reads it via
    // ControlBrowserContext.


#if DEBUG
    // Shared by `simulateShortcut` (a v1-shared body that stays here) and the
    // relocated `controlDebugSimulateType` witness in
    // `TerminalController+ControlDebugContext.swift`, so it is `internal`.
    func prepareWindowForSyntheticInput(_ window: NSWindow?) {
        guard socketCommandAllowsInAppFocusMutations(),
              let window else { return }
        // Keep socket-driven input simulation focused on the intended window without
        // paying repeated activation/order-front costs for every synthetic key event.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow || !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

#endif

    #if !DEBUG
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
    #endif

    // The v1 `set_app_focus` / `simulate_app_active` bodies moved onto
    // ControlCommandCoordinator: the token table + dispatch live in
    // `handleSurfaceSendNotifyV1`, and the `AppFocusState` write /
    // `applicationDidBecomeActive` re-run resolve through the existing
    // ``ControlAppFocusContext`` witnesses
    // (`TerminalController+ControlAppFocusContext.swift`).

    func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    // Relaxed from `private` to `internal`: relocated v1 debug/notify bodies
    // (`listSurfaces`, `notifyTarget`, `focusFromNotification`) in the
    // conformance files call this shared tab resolver, which stays here because
    // a non-relocated v1 caller also uses it.
    func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let index = Int(trimmed), index >= 0, index < tabManager.tabs.count {
            return tabManager.tabs[index]
        }

        return nil
    }

    func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Single source of truth for spatial (left-to-right, top-to-bottom) panel
        // order lives on `Workspace.orderedPanelIds`, derived from bonsplit's tab
        // ordering. This avoids relying on Dictionary iteration order and keeps the
        // serializer, the reorder gate, and the mobile observer hash consistent.
        tab.orderedPanelIds.compactMap { tab.panels[$0] }
    }

    func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalPanel(for: uuid)
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index] as? TerminalPanel
        }

        return nil
    }

    /// Relaxed to `internal` so the v1 `new_split` witness (in the
    /// workspace-context conformance file) can resolve a panel argument exactly
    /// as the legacy v1 body did.
    func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    // MARK: - Browser Panel Commands

    // MARK: - Bonsplit Pane Commands

    // MARK: - Option Parsing (sidebar metadata commands)

    private nonisolated static func tokenizeArgs(_ args: String) -> [String] {
        SidebarMetadataArgumentParser().tokenize(args)
    }

    func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptions(args)
    }

    private func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        sidebarMetadataArgumentParser.parseOptionsNoStop(args)
    }

    private func resolveTabForReport(_ args: String) -> Tab? {
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            // First try the local tabManager if available
            if let tabManager = self.tabManager,
               let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        // Only require self.tabManager when using the selected tab (no --tab arg)
        guard let tabManager = self.tabManager else { return nil }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    func parseSidebarMutationTabTarget(
        options: [String: String]
    ) -> (target: SidebarMutationTabTarget?, error: String?) {
        // `SidebarMetadataArgumentParser.parseMutationTabTarget` already returns the
        // `CmuxSidebar.SidebarMutationTabTarget` cases this controller resolves, so
        // forward the parsed target verbatim instead of re-mapping it case-for-case
        // onto a duplicate local enum.
        let resolution = sidebarMetadataArgumentParser.parseMutationTabTarget(options: options)
        return (resolution.target, resolution.error)
    }

    func resolveSidebarMutationTab(_ target: SidebarMutationTabTarget) -> Tab? {
        switch target {
        case .selected:
            guard let tabManager = self.tabManager,
                  let selectedId = tabManager.selectedTabId else {
                return nil
            }
            return tabManager.tabs.first(where: { $0.id == selectedId })
        case .workspace(let tabId):
            return tabForSidebarMutation(id: tabId)
        case .index(let index):
            guard let tabManager = self.tabManager,
                  index < tabManager.tabs.count else {
                return nil
            }
            return tabManager.tabs[index]
        }
    }

    func tabForSidebarMutation(id: UUID) -> Tab? {
        if let tab = tabManager?.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let otherManager = AppDelegate.shared?.tabManagerFor(tabId: id) {
            return otherManager.tabs.first(where: { $0.id == id })
        }
        return nil
    }

    func parseOptionalPanelIdOption(
        options: [String: String],
        usage: String
    ) -> (panelId: UUID?, error: String?) {
        let result = sidebarMetadataArgumentParser.parseOptionalPanelId(options: options, usage: usage)
        return (result.panelId, result.error)
    }

#if DEBUG
    func parseRightSidebarRemoteRequestForTesting(_ commandLine: String) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else {
            return .failure(.init(message: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode>"))
        }
        return RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(parts.count > 1 ? parts[1] : ""))
    }

    func rightSidebarCommandAllowsInAppFocusMutationsForTesting(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else { return false }
        return Self.rightSidebarCommandAllowsInAppFocusMutations(args: parts.count > 1 ? parts[1] : "")
    }
#endif

    private func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    private func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Mobile Host V2 Methods

    @MainActor
    func mobileHostHandleRPC(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        // The mobile data-plane RPC speaks `MobileHostRPCRequest` /
        // `MobileHostRPCResult` and dispatches directly to the app-side
        // `v2Mobile*` bodies. It deliberately does NOT route through the v2
        // control-socket `ControlCommandCoordinator` (whose native result type is
        // `ControlCallResult`): doing so would force a
        // `MobileHostRPCRequest → ControlRequest → ControlCallResult →
        // MobileHostRPCResult` type round-trip with no behavior change. The v2
        // control socket shares the same bodies through `handleMobileHost`, so the
        // wire bytes stay identical across both entrypoints without a bridge here.
        let result: V2CallResult
        switch request.method {
        case "mobile.host.status":
            result = v2MobileHostStatus(params: request.params, includePrivateMetadata: false)
        case "mobile.attach_ticket.create":
            result = await v2MobileAttachTicketCreate(params: request.params)
        case "mobile.workspace.list", "workspace.list":
            result = v2MobileWorkspaceList(params: request.params)
        case "workspace.create":
            result = v2MobileWorkspaceCreate(params: request.params)
        case "mobile.terminal.create", "terminal.create":
            result = v2MobileTerminalCreate(params: request.params)
        case "mobile.terminal.input", "terminal.input":
            result = v2MobileTerminalInput(params: request.params)
        case "mobile.terminal.paste", "terminal.paste":
            result = v2MobileTerminalPaste(params: request.params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            result = v2MobileTerminalPasteImage(params: request.params)
        case "mobile.terminal.replay", "terminal.replay":
            result = v2MobileTerminalReplay(params: request.params)
        case "mobile.terminal.viewport", "terminal.viewport":
            result = v2MobileTerminalViewport(params: request.params)
        case "mobile.terminal.scroll", "terminal.scroll":
            result = v2MobileTerminalScroll(params: request.params)
        case "mobile.terminal.mouse", "terminal.mouse":
            result = v2MobileTerminalMouse(params: request.params)
        case "workspace.action":
            result = v2MobileWorkspaceAction(params: request.params)
        case let method where method.hasPrefix("mobile.chat."):
            result = await v2MobileChatDispatch(method: method, params: request.params)
        case "workspace.close":
            result = v2MobileWorkspaceClose(params: request.params)
        case "workspace.group.collapse":
            result = v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: true)
        case "workspace.group.expand":
            result = v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: false)
        case "notification.dismiss":
            result = v2MobileNotificationDismiss(params: request.params)
        case "notification.reconcile":
            result = v2MobileNotificationReconcile(params: request.params)
        case "dogfood.feedback.submit":
            result = await v2MobileDogfoodFeedbackSubmit(params: request.params)
        default:
            result = .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": request.method
            ])
        }
        return mobileHostResult(result)
    }

    /// Privileged agent feedback sink (the Mac↔phone feedback loop).
    ///
    /// Reads `{ text, terminal_text, build_stamp, diagnostic_blob_base64 }` off
    /// the wire and hands them to ``DogfoodFeedbackService`` (in the
    /// `CmuxFeedback` package), which caps the fields, rejects an oversized
    /// base64 blob without decoding, and writes a self-contained bundle
    /// directory under `~/.cache/cmux-dogfood-feedback/<ISO8601>_<shortid>/`
    /// (a `bundle.json` manifest plus the decoded `diagnostic.log`) off the main
    /// actor. This method owns only the trust-boundary privilege check and the
    /// wire mapping; the validation, allocation caps, and filesystem I/O live in
    /// the service.
    ///
    /// It is protected by the same-account Stack-auth authorization the rest of
    /// the mobile data plane enforces, so it never accepts an unauthenticated
    /// caller. The phone only ever routes here for `@manaflow.ai` users on an
    /// active connection, so this exists in Release builds too (the team can
    /// dogfood beta/prod), and only a Mac that runs the watcher acts on it.
    func v2MobileDogfoodFeedbackSubmit(params: [String: Any]) async -> V2CallResult {
        // Privilege check at the trust boundary: the mobile data plane only
        // accepts same-account connections, so the caller is this Mac's own Stack
        // account. The service re-enforces the @manaflow.ai gate, but we resolve
        // the authenticated email here because it requires the main-actor
        // `MobileHostService`. (The phone also gates the route on `@manaflow.ai`
        // + `dogfood.v1`, but the Mac is the real boundary.)
        let localEmail = await MobileHostService.shared.currentAuthenticatedLocalUserEmail()
        let submission = DogfoodFeedbackSubmission(
            text: v2RawString(params, "text") ?? "",
            terminalText: v2RawString(params, "terminal_text") ?? "",
            buildStamp: v2RawString(params, "build_stamp") ?? "",
            diagnosticBlobBase64: v2RawString(params, "diagnostic_blob_base64") ?? ""
        )
        let outcome = await DogfoodFeedbackService().submit(submission, authenticatedEmail: localEmail)
        switch outcome {
        case let .written(bundlePath, diagnosticLogBytes):
            return .ok([
                "ok": true,
                "bundle_path": bundlePath,
                "diagnostic_log_bytes": diagnosticLogBytes,
            ])
        case .unauthorized:
            return .err(
                code: "unauthorized",
                message: "Feedback agent sink is restricted to privileged accounts",
                data: nil
            )
        case let .invalidParams(reason):
            return .err(code: "invalid_params", message: reason, data: nil)
        case .internalError:
            return .err(
                code: "internal_error",
                message: "Failed to persist dogfood feedback bundle",
                data: nil
            )
        }
    }

    /// Mobile-gated wrapper over ``v2WorkspaceAction(params:)``.
    func v2MobileWorkspaceAction(params: [String: Any]) -> V2CallResult {
        let rawAction = v2RawString(params, "action")
        guard Self.mobileAllowsWorkspaceAction(rawAction) else {
            return .err(
                code: "method_not_found",
                message: "Unsupported workspace action for mobile",
                data: ["action": v2OrNull(rawAction)]
            )
        }
        // Reject a present-but-malformed workspace_id like the other mobile
        // handlers, then require it to actually be present and resolvable: this
        // is a mutating action, so it must target an explicit workspace and never
        // fall back to the Mac's currently selected workspace (which
        // v2WorkspaceAction would otherwise do for a missing workspace_id).
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard v2UUID(params, "workspace_id") != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        return v2WorkspaceAction(params: params)
    }

    private func mobileHostResult(_ result: V2CallResult) -> MobileHostRPCResult {
        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .err(code, message, data):
            let safeMessage = code == "internal_error" ? "Mobile host operation failed" : message
            let safeData = code == "internal_error" ? nil : data
            return .failure(MobileHostRPCError(code: code, message: safeMessage, data: safeData))
        }
    }

    func v2MobileHostStatus(
        params: [String: Any],
        includePrivateMetadata: Bool = true
    ) -> V2CallResult {
        let status = MobileHostService.shared.statusSnapshot()
        // Single source of truth shared with the mobile listener's public-status
        // paths, so the advertised capabilities can never drift. Includes
        // workspace.actions.v1 (the mobile-gated pin/unpin/rename handler), which
        // the iOS client uses to show or hide rename/pin.
        let capabilities = MobileHostService.mobileHostCapabilities
        guard includePrivateMetadata else {
            return .ok(MobileHostService.publicStatusPayload(
                routesPayload: status.routes.map(\.mobileHostJSONObject)
            ))
        }

        let tabManager = v2ResolveTabManager(params: params)
        let workspaceCount = tabManager?.tabs.count ?? 0

        return .ok([
            "mac_device_id": MobileHostIdentity.deviceID(),
            "mac_display_name": v2OrNull(MobileHostIdentity.displayName()),
            "host_service": status.payload,
            "workspace_count": workspaceCount,
            "terminal_fidelity": "render_grid",
            "capabilities": capabilities,
        ])
    }

    #if DEBUG
    #endif

    @MainActor
    func v2MobileAttachTicketCreate(params: [String: Any]) async -> V2CallResult {
        let ttl = TimeInterval(max(30, min(v2Int(params, "ttl_seconds") ?? 600, 3600)))
        let routeID = v2OptionalTrimmedRawString(params, "route_id")
            ?? v2OptionalTrimmedRawString(params, "routeID")
        let routeKind = v2OptionalTrimmedRawString(params, "route_kind")
            ?? v2OptionalTrimmedRawString(params, "routeKind")
        let scope = v2OptionalTrimmedRawString(params, "scope")
        // scope=mac mints a Mac-wide ticket that grants access to every
        // workspace on the host. Without this, the ticket gets pinned to
        // the workspace selected at QR-generation time, and tapping any
        // other workspace from the paired iPhone falls back to Stack
        // Auth verification, which is brittle on real-world networks.
        let isMacScope = scope?.lowercased() == "mac"

        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }

        let resolvedWorkspaceID: String
        let resolvedTerminalID: String?
        if isMacScope {
            resolvedWorkspaceID = ""
            resolvedTerminalID = nil
        } else {
            guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: false) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let terminalPanel: TerminalPanel?
            if let surfaceId = resolved.surfaceId {
                guard let panel = resolved.workspace.terminalPanel(for: surfaceId) else {
                    return .err(
                        code: "invalid_request",
                        message: "terminal_id does not reference a terminal",
                        data: nil
                    )
                }
                terminalPanel = panel
            } else {
                terminalPanel = nil
            }
            resolvedWorkspaceID = resolved.workspace.id.uuidString
            resolvedTerminalID = terminalPanel?.id.uuidString
        }

        do {
            let payload = try await MobileHostService.shared.createAttachTicket(
                workspaceID: resolvedWorkspaceID,
                terminalID: resolvedTerminalID,
                ttl: ttl,
                routeID: routeID,
                routeKind: routeKind
            )
            return .ok(payload)
        } catch MobileAttachTicketStoreError.noRoutes {
            return .err(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        } catch MobileAttachTicketStoreError.routeUnavailable {
            var data: [String: Any] = [:]
            if let routeID {
                data["route_id"] = routeID
            }
            if let routeKind {
                data["route_kind"] = routeKind
            }
            return .err(
                code: "unavailable",
                message: "Requested mobile host route is not available",
                data: data.isEmpty ? nil : data
            )
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to create mobile attach ticket",
                data: ["error": String(describing: error)]
            )
        }
    }

    enum MobileTerminalAliasUUID {
        case missing
        case value(UUID)
        case invalid
        case conflict
    }

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard v2HasNonNullParam(params, key) else {
                continue
            }
            sawAlias = true
            guard let candidate = v2UUID(params, key) else {
                return .invalid
            }
            if let selected, selected != candidate {
                return .conflict
            }
            selected = selected ?? candidate
        }
        if let selected {
            return .value(selected)
        }
        return sawAlias ? .invalid : .missing
    }

    private func mobileTerminalAliasValidationError(params: [String: Any]) -> V2CallResult? {
        switch mobileTerminalAliasUUID(params: params) {
        case .missing, .value:
            return nil
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }
    }

    private func mobileWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard v2HasNonNullParam(params, "workspace_id"),
              v2UUID(params, "workspace_id") == nil else {
            return nil
        }
        return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
    }

    func clearAllMobileViewportReports(reason: String) {
        guard !mobileViewportReportsBySurfaceID.isEmpty ||
            !mobileViewportReportCleanupTimersBySurfaceID.isEmpty else {
            return
        }

        for timer in mobileViewportReportCleanupTimersBySurfaceID.values {
            timer.cancel()
        }
        let surfaceIDs = Array(mobileViewportReportsBySurfaceID.keys)
        mobileViewportReportsBySurfaceID.removeAll()
        mobileViewportReportCleanupTimersBySurfaceID.removeAll()

        for surfaceID in surfaceIDs {
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
        }
    }

    #if DEBUG
    func debugResetMobileViewportReportsForTesting() {
        clearAllMobileViewportReports(reason: "mobile.viewport.testReset")
    }

    func debugSetMobileViewportReportForTesting(
        surfaceID: UUID,
        clientID: String,
        columns: Int,
        rows: Int,
        updatedAt: Date = Date()
    ) {
        var reports = mobileViewportReportsBySurfaceID[surfaceID] ?? [:]
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: updatedAt
        )
        mobileViewportReportsBySurfaceID[surfaceID] = reports
    }

    func debugMobileViewportReportClientIDsForTesting(surfaceID: UUID) -> Set<String>? {
        guard let reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            return nil
        }
        return Set(reports.keys)
    }
    #endif

    private func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.terminalPanel(for: surfaceID)
    }

    // Still used by the v1 close-workspace witness (its v2 counterpart moved to
    // ControlCommandCoordinator). Relaxed to `internal` so the witness in the
    // workspace-context conformance file can localize the message app-side,
    // exactly as the legacy v1 body did.
    func workspaceCloseProtectedMessage() -> String {
        String(
            localized: "workspace.closeProtected.message",
            defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
        )
    }

    // Shared workspace-create implementation (restored): the workspace.create
    // command moved to ControlCommandCoordinator, but v2MobileWorkspaceCreate
    // still drives this body for the mobile data-plane create path.
    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil
    ) -> V2CallResult {
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        // Persistent per-workspace environment (issue #5995): applied to the initial
        // shell AND every later pane/surface/split, and round-tripped through session
        // restore. Socket callers must use `workspace_env`; bare `env` remains
        // layout/config spelling elsewhere and is not silently reinterpreted here.
        // Unlike `initial_env`, this is NOT gated on the presence of a layout — the
        // workspace set must apply to layout-defined surfaces too.
        let workspaceEnv = Workspace.sanitizedWorkspaceEnvironment(
            v2StringMap(params, "workspace_env") ?? [:]
        )
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        // Decode optional layout param (same JSON schema as cmux.json layout field).
        // Validate before creating the workspace so malformed layouts fail fast.
        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .err(code: "invalid_params", message: "layout must be a valid JSON object", data: nil)
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .err(code: "invalid_params", message: "Invalid layout: \(error.localizedDescription)", data: nil)
            }
        }

        var newId: UUID?
        var initialSurfaceId: UUID?
        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        let shouldEagerLoadTerminal = v2Bool(params, "eager_load_terminal") ?? !shouldFocus
        let shouldAutoRefreshMetadata = v2Bool(params, "auto_refresh_metadata") ?? true
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
                initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
                workspaceEnvironment: workspaceEnv,
                select: shouldFocus,
                eagerLoadTerminal: shouldEagerLoadTerminal,
                autoRefreshMetadata: shouldAutoRefreshMetadata
            )
            ws.setCustomDescription(description)
            if let layoutNode {
                ws.applyCustomLayout(layoutNode, baseCwd: cwd ?? ws.currentDirectory)
            }
            newId = ws.id
            initialSurfaceId = ws.focusedPanelId
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "surface_id": v2OrNull(initialSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: initialSurfaceId)
        ])
    }

    func v2MobileWorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        var createParams = params
        createParams["focus"] = false
        createParams["eager_load_terminal"] = false
        createParams["auto_refresh_metadata"] = false
        let createResult = v2WorkspaceCreate(params: createParams, tabManager: tabManager)
        switch createResult {
        case let .ok(payload):
            let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
            if let createdWorkspaceID {
                createParams["workspace_id"] = createdWorkspaceID
            }
            // workspace.updated emit is handled by MobileWorkspaceListObserver
            // which watches TabManager.tabsPublisher directly. Don't fire here.
            return v2MobileWorkspaceList(
                params: createParams,
                tabManager: tabManager,
                createdWorkspaceID: createdWorkspaceID
            )
        case .err:
            return createResult
        }
    }

    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return .err(code: "not_found", message: "Pane not found", data: nil)
        }
        guard let terminal = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            autoRefreshMetadata: false,
            preserveFocusWhenUnfocused: false, inheritWorkingDirectoryFallback: true
        ) else {
            return .err(code: "internal_error", message: "Failed to create terminal", data: nil)
        }
        // workspace.updated emit is handled by MobileWorkspaceListObserver.
        return v2MobileWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdTerminalID: terminal.id.uuidString
        )
    }

    func v2MobileTerminalReplay(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            #if DEBUG
            cmuxDebugLog("mobile.terminal.replay NOT_FOUND surface=\(v2RawString(params, "surface_id") ?? "nil")")
            #endif
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let state = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceId)
        let seq = state?.seq ?? 0
        let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            seq: seq
        )
        #if DEBUG
        cmuxDebugLog("mobile.terminal.replay surface=\(surfaceId.uuidString.prefix(8)) renderGrid=\(renderGrid != nil) seq=\(seq) hasState=\(state != nil)")
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "seq": seq,
        ]
        if let renderGrid,
           let renderGridObject = try? renderGrid.jsonObject() {
            payload["columns"] = renderGrid.columns
            payload["rows"] = renderGrid.rows
            payload["render_grid"] = renderGridObject
        } else {
            let snapshotData = readTerminalTextFromVTExportForSnapshot(
                terminalPanel: terminalPanel,
                bindingAction: "write_active_file:copy,vt",
                lineLimit: nil,
                normalizeLineEndings: false
            )?.data(using: .utf8) ?? Data()
            let data = state?.data ?? Data()
            if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalReplay") {
                let size = ghostty_surface_size(surface)
                payload["columns"] = max(Int(size.columns), 1)
                payload["rows"] = max(Int(size.rows), 1)
            }
            if !snapshotData.isEmpty {
                payload["snapshot_format"] = "ghostty.active.vt"
                payload["snapshot_data_b64"] = snapshotData.base64EncodedString()
            } else if !data.isEmpty {
                payload["data_b64"] = data.base64EncodedString()
            }
        }
        return .ok(payload)
    }

    /// Record (or clear) a paired device's reported terminal grid, recompute
    /// the smallest grid across all attached devices, cap this surface to it
    /// (drawing the macOS viewport border when the pane is larger), and return
    /// the resulting effective grid so the device can pin + letterbox its own
    /// render to match. This is the iOS/macOS half of the tmux-style shared
    /// resize: the smallest attached viewport wins and every device shows the
    /// same cols×rows with a clear border around the live area.
    func v2MobileTerminalViewport(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        if v2Bool(params, "clear") == true {
            if let clientID = v2String(params, "client_id") {
                clearMobileViewportReport(
                    surfaceID: terminalPanel.id,
                    clientID: clientID,
                    reason: "mobile.terminal.viewport.clear"
                )
            }
        } else {
            applyMobileViewportReport(params: params, terminalPanel: terminalPanel, sticky: true)
        }

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ]
        if let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileTerminalViewport") {
            let size = ghostty_surface_size(surface)
            payload["columns"] = max(Int(size.columns), 1)
            payload["rows"] = max(Int(size.rows), 1)
        }
        return .ok(payload)
    }

    /// Forward a phone scroll gesture to the real surface so libghostty handles
    /// it per-mode (scrollback in the normal screen, mouse-wheel to the program
    /// in the alt screen). The producer already exports the live `vp_top`, so
    /// the resulting viewport mirrors back to the phone; nudge an emit since a
    /// pure scroll with no PTY output may not fire a render/tick on its own.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let deltaLines = (params["delta_lines"] as? NSNumber)?.doubleValue ?? 0
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        if deltaLines != 0 {
            terminalPanel.surface.mobileScroll(deltaLines: deltaLines, col: max(0, col), row: max(0, row))
            MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        }
        return .ok(mobileTerminalScrollResponsePayload(
            workspaceID: resolved.workspace.id,
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            params: params
        ))
    }

    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        terminalPanel.surface.mobileClick(col: max(0, col), row: max(0, row))
        MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
        ])
    }

    func v2MobileTerminalInput(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        #if DEBUG
        let sendStart = ProcessInfo.processInfo.systemUptime
        #endif
        let sendResult = terminalPanel.surface.sendInputResult(text)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalInput")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
        cmuxDebugLog(
            "mobile.terminal.input workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) queued=\(sendResult == .queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
        )
        #endif
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ]
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    /// Handle `terminal.paste_image`: a paired client (the iOS app) forwards an
    /// image it pasted as base64 bytes. We materialize it to a temp file on the
    /// Mac and inject the shell-escaped path as terminal input, exactly the way a
    /// local clipboard-image paste does, so the running TUI (e.g. Claude Code)
    /// attaches the image from the path.
    func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {
        guard let base64 = v2RawString(params, "image_base64"),
              let imageData = Data(base64Encoded: base64), !imageData.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid image_base64", data: nil)
        }
        let format = v2RawString(params, "image_format") ?? "png"
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        guard let escapedPath = GhosttyApp.terminalPasteboard.saveImageData(imageData, fileExtension: format) else {
            return .err(code: "invalid_params", message: "Image payload was empty or exceeded the size limit", data: nil)
        }

        let sendResult = terminalPanel.surface.sendInputResult(escapedPath)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPasteImage")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": surfaceId.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": surfaceId.uuidString])
        }
        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste_image workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) bytes=\(imageData.count) format=\(format)"
        )
        #endif
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": sendResult == .queued,
        ])
    }

    /// Deliver a composed block from the mobile composer as a bracketed paste
    /// followed by an optional single submit key.
    ///
    /// This mirrors the macOS TextBox composer dispatch
    /// (`[.pasteText(payload), .namedKey(submitKey)]`): the text goes through
    /// `sendText` (libghostty `ghostty_surface_text`), which bracketed-pastes it
    /// (`ESC[200~ … ESC[201~` when DECSET 2004 is active) so the agent's line
    /// editor inserts the whole, possibly multi-line, block as literal text
    /// instead of treating every interior newline as a submit. A single named
    /// submit key then commits it once. The `terminal.input` path is wrong for a
    /// composed block: `parsedSocketInputEvents` rewrites every `\n`/`\r` to a
    /// raw CR, so an N-line message fragments into N submissions.
    ///
    /// `submit_key` is optional: `return`/`enter` (default) or `ctrl+enter`
    /// submit; `none` pastes without submitting so the composer can keep editing.
    func v2MobileTerminalPaste(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        // Resolve the optional submit key up front so an unsupported value fails
        // before any text is pasted (no partial application). The phone sends
        // `return` as the default submit *intent*; the agent-aware upgrade to
        // `ctrl+enter` happens below once the surface (and its agent context) is
        // resolved, because only the Mac knows which agent is running.
        let submitKeyRaw = (v2String(params, "submit_key") ?? "return").lowercased()
        var submitKeyName: String?
        var submitKeyWasReturnIntent = false
        switch submitKeyRaw {
        case "", "return", "enter":
            submitKeyName = "return"
            submitKeyWasReturnIntent = true
        case "ctrl+enter":
            submitKeyName = "ctrl+enter"
        case "none":
            submitKeyName = nil
        default:
            return .err(code: "invalid_params", message: "Unsupported submit_key", data: ["submit_key": submitKeyRaw])
        }
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }

        // Mirror the macOS TextBox composer's submit-key selection
        // (`TextBoxInput.dispatchEvents`): Claude Code needs `ctrl+enter` to
        // submit a multi-line block, while plain `return` submits a newline mid
        // prompt. The phone cannot know the running agent, so it always asks for
        // `return`; upgrade that intent here when the surface is Claude and the
        // composed text spans multiple lines. Explicit `ctrl+enter`/`none` from
        // the client are honored as-is.
        if submitKeyWasReturnIntent,
           text.contains("\n") || text.contains("\r"),
           TextBoxAgentDetection.isClaudeCode(
               context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
           ) {
            submitKeyName = "ctrl+enter"
        }

        applyMobileViewportReport(params: params, terminalPanel: terminalPanel)

        // Send through the TerminalPanel explicit-input wrappers (not the raw
        // surface): they run `resumeForExplicitInputIfNeeded()` first, waking a
        // hibernated agent terminal the same way local typing does, so a mobile
        // composer submit cannot write into a cold surface.
        guard terminalPanel.sendText(text) else {
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": surfaceId.uuidString])
        }

        // The paste text is already accepted by the surface above. From here on a
        // submit-key failure must NOT surface as an RPC error: the client treats
        // any error as "nothing was sent" and keeps the composer draft, so a
        // retry would paste the whole block a second time. Report partial
        // success instead — `submitted: false` plus `submit_error` — so the
        // client clears the draft (the text is sitting at the prompt) and can
        // tell the user the submit keypress is still needed.
        var submitted = false
        var submitError: String?
        if let submitKeyName {
            let keyResult = terminalPanel.sendNamedKeyResult(submitKeyName)
            if keyResult.accepted {
                submitted = true
            } else {
                switch keyResult {
                case .inputQueueFull:
                    submitError = "input_queue_full"
                case .surfaceUnavailable:
                    submitError = "surface_unavailable"
                case .processExited:
                    submitError = "process_exited"
                case .unknownKey, .sent, .queued:
                    // .sent / .queued are accepted results and unreachable in this
                    // else-branch; grouped here only to keep the switch exhaustive.
                    submitError = "unknown_key"
                }
            }
        }

        terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPaste")

        #if DEBUG
        cmuxDebugLog(
            "mobile.terminal.paste workspace=\(resolved.workspace.id.uuidString.prefix(8)) surface=\(surfaceId.uuidString.prefix(8)) chars=\(text.count) submitted=\(submitted ? 1 : 0)"
        )
        #endif

        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "submitted": submitted,
        ]
        if let submitError {
            payload["submit_error"] = submitError
        }
        if let seq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceId) {
            payload["terminal_seq"] = seq
        }
        return .ok(payload)
    }

    private func applyMobileViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool = false
    ) {
        guard let clientID = v2String(params, "client_id"),
              let rawColumns = v2Int(params, "viewport_columns"),
              let rawRows = v2Int(params, "viewport_rows") else {
            return
        }

        let columns = min(max(rawColumns, 20), 300)
        let rows = min(max(rawRows, 5), 120)
        let now = Date()
        var reports = mobileViewportReportsBySurfaceID[terminalPanel.id] ?? [:]
        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }
        reports[clientID] = MobileViewportReport(
            columns: columns,
            rows: rows,
            updatedAt: now,
            sticky: sticky
        )
        mobileViewportReportsBySurfaceID[terminalPanel.id] = reports
        scheduleMobileViewportReportCleanup(surfaceID: terminalPanel.id, reports: reports)

        guard let minColumns = reports.values.map(\.columns).min(),
              let minRows = reports.values.map(\.rows).min() else {
            return
        }
        terminalPanel.surface.applyMobileViewportLimit(
            columns: minColumns,
            rows: minRows,
            reason: "mobile.terminal.input"
        )
    }

    /// Remove a single client's viewport report for a surface (dedicated
    /// `mobile.terminal.viewport` clear, or a disconnect), then recompute the
    /// remaining min and re-apply or clear the surface's viewport limit so the
    /// macOS border reflects only the devices still attached.
    private func clearMobileViewportReport(surfaceID: UUID, clientID: String, reason: String) {
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID],
              reports.removeValue(forKey: clientID) != nil else {
            return
        }
        if reports.isEmpty {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }
        mobileViewportReportsBySurfaceID[surfaceID] = reports
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
    }

    /// Drop every viewport report owned by the given client IDs across all
    /// surfaces. Called when a mobile connection closes so a disconnected
    /// device stops pinning the grid even though it never sent an explicit
    /// clear. Sticky reports rely on this signal instead of the TTL.
    func clearMobileViewportReports(clientIDs: Set<String>, reason: String) {
        guard !clientIDs.isEmpty else { return }
        for surfaceID in Array(mobileViewportReportsBySurfaceID.keys) {
            for clientID in clientIDs {
                clearMobileViewportReport(surfaceID: surfaceID, clientID: clientID, reason: reason)
            }
        }
    }

    private func scheduleMobileViewportReportCleanup(
        surfaceID: UUID,
        reports: [String: MobileViewportReport]
    ) {
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
        // Sticky reports live for the connection lifetime, so they never drive
        // a TTL timer; only non-sticky (input-piggyback) reports expire.
        guard let nextExpiry = reports.values
            .filter({ !$0.sticky })
            .map({ $0.updatedAt.addingTimeInterval(Self.mobileViewportReportTTL) })
            .min() else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let millisecondsUntilExpiry = max(1, Int((nextExpiry.timeIntervalSinceNow + 1) * 1000))
        timer.schedule(deadline: .now() + .milliseconds(millisecondsUntilExpiry))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.pruneMobileViewportReports(surfaceID: surfaceID, reason: "mobile.viewport.reportsExpired")
            }
        }
        mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = timer
        timer.resume()
    }

    private func pruneMobileViewportReports(surfaceID: UUID, reason: String) {
        let now = Date()
        guard var reports = mobileViewportReportsBySurfaceID[surfaceID] else {
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            return
        }

        reports = reports.filter { _, report in
            report.sticky || now.timeIntervalSince(report.updatedAt) <= Self.mobileViewportReportTTL
        }

        guard !reports.isEmpty else {
            mobileViewportReportsBySurfaceID[surfaceID] = nil
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID]?.cancel()
            mobileViewportReportCleanupTimersBySurfaceID[surfaceID] = nil
            terminalPanel(surfaceID: surfaceID)?.surface.clearMobileViewportLimit(reason: reason)
            return
        }

        mobileViewportReportsBySurfaceID[surfaceID] = reports
        if let minColumns = reports.values.map(\.columns).min(),
           let minRows = reports.values.map(\.rows).min() {
            terminalPanel(surfaceID: surfaceID)?.surface.applyMobileViewportLimit(
                columns: minColumns,
                rows: minRows,
                reason: reason
            )
        }
        scheduleMobileViewportReportCleanup(surfaceID: surfaceID, reports: reports)
    }

    func mobileResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (tabManager: TabManager, workspace: Workspace, surfaceId: UUID?)? {
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return nil
        }

        let requestedSurfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id")

        let surfaceId: UUID?
        if let requestedSurfaceId {
            guard workspace.panels[requestedSurfaceId] != nil else {
                return nil
            }
            surfaceId = requestedSurfaceId
        } else if requireTerminal {
            surfaceId = workspace.focusedTerminalPanel?.id
                ?? mobileTerminalPanels(in: workspace).first?.id
        } else {
            surfaceId = nil
        }

        // A session-restored / never-foregrounded terminal has its libghostty
        // surface created lazily — today only on the first keystroke (via the
        // input path's `requestBackgroundSurfaceStartIfNeeded`). The mobile
        // render-grid producer only reads a *live* surface, so such a terminal
        // shows blank on the phone until the user types. When a mobile client
        // resolves a terminal to read or drive, materialize the surface
        // headlessly so attaching alone loads it. Idempotent and a no-op once
        // the surface exists.
        if requireTerminal,
           let surfaceId,
           let panel = workspace.terminalPanel(for: surfaceId) {
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
        }

        return (tabManager, workspace, surfaceId)
    }

    func mobileTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        // Use the workspace's spatial (left-to-right, top-to-bottom) panel order
        // so the phone's terminal dropdown matches the on-screen bonsplit layout,
        // rather than focused-first/UUID order. `is_focused` in the payload still
        // tells the phone which terminal is active.
        orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }
    }

    func mobileNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    deinit {
        if let browserDownloadObserver {
            NotificationCenter.default.removeObserver(browserDownloadObserver)
        }
        // No stop() here: the controller is an app-lifetime singleton, so
        // deinit never runs; listener teardown is applicationWillTerminate's
        // synchronous stop() on the main actor.
    }
}
