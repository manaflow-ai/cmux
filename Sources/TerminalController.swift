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
    // The browser-download-event and react-grab-copy notification names are owned
    // by `BrowserAutomationController` (CmuxBrowser), which registers the
    // download observer. These app-side aliases keep every existing call site
    // (`.browserDownloadEventDidArrive` / `.reactGrabDidCopySelection`) byte
    // identical while the canonical definition (the same string) lives with the
    // state owner.
    static let browserDownloadEventDidArrive = BrowserAutomationController.browserDownloadEventDidArriveName
    static let reactGrabDidCopySelection = BrowserAutomationController.reactGrabDidCopySelectionName
}

/// Unix socket-based controller for programmatic terminal control
/// Allows automated testing and external control of terminal tabs
///
/// This is the app-target composition owner for external programmatic control:
/// it constructs and holds the package-owned ``SocketControlServer`` (socket
/// lifecycle: bind/accept/listen, path/lock/generation state machine, backoff
/// rearm), the ``ControlCommandCoordinator`` (RPC dispatch + handle registry),
/// every worker-lane RPC handler, and conforms ``ControlCommandContext`` so the
/// coordinator can read live window/workspace/tab state without importing the
/// app target.
///
/// De-singletonization stage (b72): the former self-vivifying
/// `static let shared = TerminalController()` is retired. The instance is now
/// constructed once at the composition root (``AppDelegate`` in
/// `applicationDidFinishLaunching`), which holds it as `terminalControl` and is
/// its sole owner. ``shared`` is a transitional accessor that returns the
/// composition-root instance (falling back to lazy construction only for unit
/// tests / pre-launch access), kept while the tail of call sites is rewired to
/// the injected reference. The eventual end state renames this type
/// `TerminalControlComposition` and drops ``shared`` entirely.
@MainActor
class TerminalController: MobileViewportSurfaceLimiting {
    /// Records that the composition root (``AppDelegate``) has claimed ownership
    /// of the single instance, so the tail call sites reaching ``shared`` and the
    /// root's own ``AppDelegate/terminalControl`` reference resolve to the same
    /// object. `nonisolated(unsafe)`: written exactly once at startup (ahead of
    /// the socket listener) before any concurrent reader exists. Retires with
    /// ``shared`` once every call site is injected.
    nonisolated(unsafe) private static var compositionRootInstance: TerminalController?

    /// The single instance, lazily constructed on first access. A `static let` of
    /// a `@MainActor` type is nonisolated-readable and its initializer runs the
    /// `@MainActor` `init`, exactly the legacy `static let shared` contract that
    /// the `nonisolated static` focus-allowance methods read. In a normal launch
    /// the composition root resolves and installs this first (via
    /// ``installCompositionRootInstance(_:)``) and holds it as
    /// ``AppDelegate/terminalControl``.
    private static let instance = TerminalController()

    /// Transitional accessor for the de-singletonization. The type no longer
    /// self-vivifies an eager `static let shared`; ownership lives at the
    /// composition root (``AppDelegate/terminalControl``), which constructs and
    /// holds the instance and uses it directly. The tail of call sites (cmuxApp,
    /// Workspace, the `nonisolated static` focus-allowance methods, the
    /// `+Control*Context` seams, tests) still reach the same single object here
    /// while they are migrated to the injected reference; this accessor and the
    /// type rename to `TerminalControlComposition` are the end state.
    nonisolated static var shared: TerminalController {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` at startup to record composition-root
    /// ownership of the single instance. Idempotent (keeps the first installed
    /// instance).
    nonisolated static func installCompositionRootInstance(_ instance: TerminalController) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

    /// Pure replacement-policy transforms for sidebar status/metadata/git/PR/
    /// port projections plus directory normalization and explicit-socket-scope
    /// parsing. A `Sendable` value type owned by `CmuxSidebar`; the sidebar
    /// control path (the `ControlSidebarContext` witnesses) calls it before
    /// upserting a projection.
    let sidebarReplacementPolicy = SidebarReplacementPolicy()

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
    @MainActor var mobileChatHandlerStorage: MobileChatRPCHandler? // owned mobile.chat.* dispatch handler (built lazily; see TerminalController+MobileChat.swift)
    @MainActor var mobileWorkspaceListHandlerStorage: MobileWorkspaceListRPCHandler? // owned mobile.workspace.list/close/group dispatch handler (built lazily; see TerminalController+MobileWorkspaceList.swift)
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
    /// The pure focus-mutation classification tables (CmuxControlSocket). Holds
    /// no live state; one source of truth for which commands may steal focus.
    nonisolated let socketCommandPolicy = ControlSocketCommandPolicy.standard
    /// The runtime focus-allowance stack (CmuxControlSocket), injected per-router
    /// state replacing the former process-wide `socketCommandFocusAllowanceStackKey`
    /// thread-dictionary static. One instance per controller (one router per
    /// process today), so the allowance is genuinely instance-scoped.
    nonisolated let socketCommandFocusAllowance = ControlSocketFocusAllowanceStack()
    private nonisolated static let socketListenerFailureCaptureCooldown: TimeInterval = 60
    // The download-wait timeout bounds moved to `BrowserAutomationController`
    // (CmuxBrowser); these aliases keep the worker-lane call sites byte identical.
    private nonisolated static let v2BrowserDownloadWaitDefaultTimeoutMs =
        BrowserAutomationController.downloadWaitDefaultTimeoutMs
    private nonisolated static let v2BrowserDownloadWaitMaxTimeoutMs =
        BrowserAutomationController.downloadWaitMaxTimeoutMs
    private nonisolated static let socketListenerFailureCaptureLock = NSLock()
    private nonisolated(unsafe) static var socketListenerFailureLastCapturedAt: [String: Date] = [:]
    /// Reference to the shared mobile-terminal viewport state machine
    /// (per-surface, per-client reported grids + TTL cleanup), whose owning model
    /// type `HostMobileViewportReportModel` lives in `CMUXMobileCore`. Lazily
    /// constructed so the limiter seam can capture `self`; the model holds only
    /// its own state and drives surface caps through ``MobileViewportSurfaceLimiting``
    /// (conformed in `TerminalController+MobileViewport.swift`). `internal` so the
    /// viewport-seam extension in that sibling file can reach it; the model itself
    /// stays the single owner of the state.
    lazy var mobileViewportReportModel = HostMobileViewportReportModel(limiter: self)
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

    /// The bounded blocking-await primitive (CmuxControlSocket) every worker-lane
    /// browser JS-eval path blocks on. Stateless and `Sendable`, so a single
    /// shared instance serves every call; read from the nonisolated socket-worker
    /// lane via `v2AwaitCallback`. Also injected into ``browserAutomation`` so the
    /// cookie-store I/O blocks on the same primitive.
    private nonisolated static let browserEvalAwaiter = ControlBrowserEvalAwaiter()

    /// The owner of all per-browser-surface automation state plus the stateless
    /// substrate the `browser.*` commands read it through, extracted to
    /// `CmuxBrowser` as a `@MainActor @Observable` store. It owns the per-surface
    /// caches (element refs, frame selector, init scripts/styles, dialog queue,
    /// download events, not-supported network log), the ``BrowserControlService``
    /// script substrate, the ``BrowserCookieRepository`` cookie source of truth,
    /// the captured-download observer, and the download/dialog/network state
    /// bookkeeping. The app target keeps only the WebKit JS-eval core
    /// (`v2RunJavaScript` / `v2RunBrowserJavaScript`), whose main hop propagates
    /// the app-target socket-command focus-policy stack, and reads/mutates every
    /// byte of automation state through this instance.
    let browserAutomation = BrowserAutomationController(
        cookies: BrowserCookieRepository(awaiter: TerminalController.browserEvalAwaiter)
    )

    /// The stateless browser-control logic, vended by ``browserAutomation``. A
    /// thin forwarder so the many app-side eval-core call sites keep reading
    /// `v2BrowserControl` while the value lives on the state owner.
    nonisolated var v2BrowserControl: BrowserControlService { browserAutomation.control }

    /// The per-surface automation caches, vended by ``browserAutomation``. A thin
    /// forwarder so the `@MainActor` witnesses keep reading `v2BrowserSurfaceState`
    /// while the state lives on the owner.
    var v2BrowserSurfaceState: BrowserAutomationSurfaceState { browserAutomation.surfaceState }

    /// The cookie source of truth, vended by ``browserAutomation``.
    nonisolated var v2BrowserCookieRepository: BrowserCookieRepository { browserAutomation.cookies }

    func cleanupSurfaceState(surfaceIds: [UUID]) {
        browserAutomation.cleanupSurfaces(surfaceIds)
        for surfaceId in Set(surfaceIds) {
            controlCommandCoordinator.removeRef(kind: .surface, uuid: surfaceId)
        }
    }

    /// Bridges the package server's event closures back to the controller.
    /// Assigned exactly once during `init`, before the listener can start, and
    /// read-only afterward; the controller is an app-lifetime singleton.
    private final class ServerEventTarget: @unchecked Sendable {
        weak var controller: TerminalController?
    }

    /// Constructed once at the composition root (``AppDelegate``); no longer
    /// `private` so the composition root can build and own the instance instead
    /// of the type self-vivifying it. Collaborators are constructor-injected
    /// (password store, socket transport, listener policy, remote-proxy broker),
    /// matching the no-singleton DI rule.
    init(
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
                controller.spawnConnectionHandler(for: connection)
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
        // The captured-download observer is registered by `browserAutomation`
        // (CmuxBrowser), which owns the per-surface download backlog it appends to.
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
        shared.socketCommandFocusAllowance.isCommandActive
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        shared.socketCommandFocusAllowance.topAllowsFocusMutation
    }

    /// Relaxed to `internal` so the v1 `move_workspace_to_window` /
    /// `new_workspace` witnesses (in the workspace-context conformance file) can
    /// read the active socket command's focus-allowance, matching the legacy v1
    /// bodies exactly.
    func socketCommandAllowsInAppFocusMutations() -> Bool {
        socketCommandFocusAllowance.topAllowsFocusMutation
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

    /// Classifies whether a command of this shape may mutate in-app focus.
    /// Extracts the two `Any`-shaped legacy inputs (the v2 `focus` param and the
    /// v1 `right_sidebar` args) here in the app target and forwards the resolved
    /// booleans to the pure ``ControlSocketCommandPolicy``.
    private nonisolated static func socketCommandAllowsInAppFocusMutations(commandKey: String, isV2: Bool, params: [String: Any] = [:]) -> Bool {
        shared.socketCommandPolicy.allowsInAppFocusMutations(
            commandKey: commandKey,
            isV2: isV2,
            explicitFocusParam: isV2 && explicitFocusParamValue(params),
            rightSidebarAllowsFocus: !isV2 && commandKey == "right_sidebar"
                ? rightSidebarCommandAllowsInAppFocusMutations(args: params["args"] as? String ?? "")
                : false
        )
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
        return socketCommandFocusAllowance.withPolicy(allowsInAppFocusMutations: allowsFocusMutation, body)
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

    // The VT-export path helpers now live on `TerminalSurface` in
    // `CmuxTerminal` (`TerminalSurface+TextRead.swift`), beside the VT-export
    // reader that uses them. These app-target entry points forward to the
    // single package implementation so existing unit tests
    // (`SessionPersistenceTests`) keep calling `TerminalController.…`.
    nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        TerminalSurface.normalizedExportedScreenPath(raw)
    }

    nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        TerminalSurface.shouldRemoveExportedScreenFile(
            fileURL: fileURL,
            temporaryDirectory: temporaryDirectory
        )
    }

    nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        TerminalSurface.shouldRemoveExportedScreenDirectory(
            fileURL: fileURL,
            temporaryDirectory: temporaryDirectory
        )
    }

    nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        TerminalSurface.normalizedMobileVTExportText(text)
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

    /// The control-socket password handshake, bound to the live listener
    /// access mode. The connection transport pipeline (access control, the
    /// `events.stream` auth gate, line framing, the write) and the per-command
    /// auth gate in ``processSocketLine(_:authenticated:)`` share this single
    /// authenticator — the legacy `authResponseIfNeeded` family, now in
    /// ``ControlPasswordAuthenticator``.
    private nonisolated func passwordAuthenticator() -> ControlPasswordAuthenticator {
        ControlPasswordAuthenticator(
            passwordStore: passwordStore,
            accessMode: socketServer.accessMode
        )
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
             "browser.is.visible", "browser.is.enabled", "browser.is.checked",
             "browser.eval", "browser.snapshot", "browser.wait":
            // The read-only `browser.get.*` / `browser.is.*` getters and the
            // eval-result reads `browser.eval` / `browser.snapshot` /
            // `browser.wait` are owned by CmuxControlSocket's
            // ``ControlBrowserQueryWorker`` (alongside `browser.find.*`), reaching
            // the live browser surface through the ``ControlBrowserQueryReading``
            // seam (`controlResolveBrowserQuery`). Refresh refs first like the
            // legacy shared dispatch did for every JS-eval browser method.
            v2MainSync { self.v2RefreshKnownRefs() }
            return runBrowserQueryWorker(request.control)
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

    /// Spawns the package per-connection handler for `connection` on its own
    /// detached thread (the legacy `spawnClientHandler` role). The handler owns
    /// the access-control gate, the password handshake, line framing, and the
    /// write; command bodies route back here through the
    /// ``ControlClientCommandDispatching`` conformance.
    nonisolated func spawnConnectionHandler(for connection: ControlConnection) {
        let handler = ControlClientConnectionHandler(
            socket: connection.socket,
            peerProcessID: connection.peerProcessID,
            transport: transport,
            accessMode: { [socketServer] in socketServer.accessMode },
            selfProcessID: getpid(),
            isRunning: { [socketServer] in socketServer.isRunning },
            makeAuthenticator: { [self] in passwordAuthenticator() },
            dispatcher: self
        )
        ControlClientConnectionHandler.spawnDetached(handler)
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

    nonisolated func processSocketLine(
        _ command: String,
        authenticated: Bool
    ) -> ControlClientCommandOutcome {
#if DEBUG
        // Per-command debug-log classification (begin/end lines, slow/error
        // gating, method-token sanitization, JSON status scan) lives in
        // CmuxControlSocket's `ControlSocketCommandLog`; the debug sink
        // (`cmuxDebugLog`) stays app-side, so this path logs whatever non-nil
        // message the classifier returns, exactly where the legacy code did.
        let commandLog = ControlSocketCommandLog()
        let debugInfo = commandLog.info(forCommand: command)
        let debugStart = DispatchTime.now().uptimeNanoseconds
        let debugLoggingEnabled = commandLog.isLoggingEnabled
        if debugLoggingEnabled {
            cmuxDebugLog(commandLog.beginMessage(for: debugInfo))
        }
#endif
        let authDecision = passwordAuthenticator().response(for: command, authenticated: authenticated)
        let nextAuthenticated = authDecision.authenticated
        if let response = authDecision.response {
#if DEBUG
            if let endMessage = commandLog.endMessageIfNeeded(
                info: debugInfo,
                startedAtUptimeNanos: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            ) {
                cmuxDebugLog(endMessage)
            }
#endif
            return ControlClientCommandOutcome(response: response, authenticated: nextAuthenticated)
        }

        let response = processCommandUsingSocketExecutionPolicy(command)
#if DEBUG
        if let response,
           let endMessage = commandLog.endMessageIfNeeded(
            info: debugInfo,
            startedAtUptimeNanos: debugStart,
            response: response,
            loggingEnabled: debugLoggingEnabled
           ) {
            cmuxDebugLog(endMessage)
        }
#endif
        return ControlClientCommandOutcome(response: response, authenticated: nextAuthenticated)
    }

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
        // surface.refresh/health/resume.set/get/clear, debug.terminals (the
        // app-coupled body lives in the controlDebugTerminals() witness),
        // surface.send_text/send_key/report_tty/
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
        // this switch. find/navigation/interaction and the read-only/eval-result
        // reads (get/is, eval/snapshot/wait) are owned by CmuxControlSocket's
        // ControlBrowser{Query,Navigation,Interaction}Worker.
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
                    systemTopWorkspaceNode(
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
        // The former inline `intParam` closure was a byte-equivalent twin of the
        // shared `v2StrictIntAny` strict-integer parser (non-boolean integral
        // number truncated toward zero with range/finite guards, or a decimal
        // string), so the group-limit validation reuses the single shared helper
        // rather than carrying a duplicate parser in the god dispatch path.
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = v2StrictIntAny(params[key]), (1...100).contains(value) else {
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
                    let workspaceNode = systemTopWorkspaceNode(
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
                    systemTopWorkspaceNode(
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

    // The byte-faithful `v2TopWindowNode` / `v2TopWorkspaceNode` / `v2TopTagNodes`
    // payload builders moved to TerminalController+ControlSystemTopContext.swift
    // (live-state tree walk producing typed `ControlSystemTopWindowNode` /
    // `ControlSystemTopWorkspaceNode`) and ControlCommandCoordinator+SystemTop.swift
    // (the dictionary shaping, including the window/selected-workspace ref minting).
    // The app `v2TopWindowNode(summary:index:workspaceNodes:)` bridge lives in that
    // conformance file.

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
        let policyStack = socketCommandFocusAllowance.currentStack()
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                socketCommandFocusAllowance.withStack(policyStack) {
                    body()
                }
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                socketCommandFocusAllowance.withStack(policyStack) {
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

    // The terminal-text snapshot readers now live on `TerminalSurface` in
    // `CmuxTerminal` (`TerminalSurface+TextRead.swift`), beside the existing
    // Ghostty-pointer read path (`TerminalSurface.readText(surface:pointTag:)`)
    // and the pure payload assembly (`TerminalTextPayload.make`,
    // `String.terminalTextTail`). The methods below are thin forwarders that
    // preserve the panel-level `TerminalPanel.performBindingAction(_:)`
    // agent-hibernation guard and inject the shared
    // `GhosttyApp.terminalPasteboard`; their signatures are unchanged so every
    // caller (the control-plane conformances, the mobile replay path,
    // hibernation, session snapshot, and the cmd-click UI test recorder) is
    // byte-identical.
    func readTerminalTextRawSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        terminalPanel.surface.readTextRawSnapshot(includeScrollback: includeScrollback)
    }

    // Stays callable from the relocated v1 `readTerminalTextBase64(surfaceArg:)`
    // body (now in `TerminalController+ControlSurfaceSendNotifyV1.swift`) and
    // the v2 read path; both pass a `TerminalPanel`.
    func readTerminalTextBase64(terminalPanel: TerminalPanel, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        terminalPanel.surface.readTextBase64(
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    private func readTerminalTextFromVTExportForSnapshot(
        terminalPanel: TerminalPanel,
        bindingAction: String = "write_screen_file:copy,vt",
        lineLimit: Int?,
        normalizeLineEndings: Bool = true
    ) -> String? {
        terminalPanel.surface.readTextFromVTExportForSnapshot(
            pasteboard: GhosttyApp.terminalPasteboard,
            performBindingAction: { terminalPanel.performBindingAction(bindingAction) },
            bindingAction: bindingAction,
            lineLimit: lineLimit,
            normalizeLineEndings: normalizeLineEndings
        )
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        allowVTExport: Bool = true
    ) -> String? {
        terminalPanel.surface.readTextForSnapshot(
            pasteboard: GhosttyApp.terminalPasteboard,
            performBindingAction: { terminalPanel.performBindingAction("write_screen_file:copy,vt") },
            includeScrollback: includeScrollback,
            lineLimit: lineLimit,
            allowVTExport: allowVTExport
        )
    }

    func readTerminalTextForHibernationFingerprint(
        terminalPanel: TerminalPanel,
        lineLimit: Int
    ) -> String? {
        terminalPanel.surface.readTextForHibernationFingerprint(lineLimit: lineLimit)
    }

    func readTerminalTextForSessionSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        terminalPanel.surface.readTextForSessionSnapshot(
            pasteboard: GhosttyApp.terminalPasteboard,
            performBindingAction: { terminalPanel.performBindingAction("write_screen_file:copy,vt") },
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
        v2BrowserControl.normalizeJSValue(value)
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
        // Pure script assembly lives in `BrowserControlService` (CmuxBrowser); the
        // WebKit evaluation below stays here on the worker lane.
        let waitScript = v2BrowserControl.conditionWaitScript(
            conditionScript: conditionScript,
            timeoutMs: timeoutMs
        )

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

    // `v2BrowserSelector`, `v2BrowserAllocateElementRef`,
    // `v2BrowserResolveSelector`, and `v2BrowserCurrentFrameSelector` moved to
    // `BrowserAutomationController` (CmuxBrowser) as `selector(in:)`,
    // `allocateElementRef(surfaceId:selector:)`, `resolveSelector(_:surfaceId:)`,
    // and `currentFrameSelector(surfaceId:)` (pure per-surface state reads whose
    // main hop performs no focus mutation, so the owner's plain main hop is
    // behavior-faithful to the former `v2MainSync`). Call sites read
    // `browserAutomation.<x>` directly.

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
        // Pure script assembly (frame prelude, execution block, async wrapper,
        // pre-macOS-11 fallback) lives in `BrowserControlService` (CmuxBrowser);
        // the WebKit evaluation and envelope unwrapping below stay here on the
        // worker lane.
        let asyncFunctionBody = v2BrowserControl.evalFunctionBody(
            script: script,
            frameSelector: browserAutomation.currentFrameSelector(surfaceId: surfaceId),
            useEval: useEval
        )

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
            let evaluateFallback = v2BrowserControl.evaluateFallbackScript(asyncFunctionBody: asyncFunctionBody)
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
            // Envelope unwrap (undefined sentinel vs carried value vs raw
            // passthrough) is a stateless transform in `BrowserControlService`
            // (CmuxBrowser); the WebKit evaluation above stays here on the worker
            // lane.
            return .success(v2BrowserControl.unwrapEvalEnvelope(value))
        }
    }

    // The not-supported-network-request record/read, the pending-dialog wire
    // projection, the dialog enqueue, and the download pop/wait moved to
    // `BrowserAutomationController` (CmuxBrowser); call sites read
    // `browserAutomation.<x>` directly. These are pure per-surface state ops; the
    // owner's main hop performs no focus mutation, so it is behavior-faithful to
    // the former `v2MainSync`.

    // v2BrowserPopDialog and v2BrowserEnsureInitScriptsApplied were drained with
    // the browser addscript/dialog domain (CmuxControlSocket
    // ControlCommandCoordinator+BrowserScriptDialog): both were dead private
    // holdovers with zero callers in Sources/CLI/cmuxTests (init scripts are now
    // applied only via the WKUserScript registration in the addinitscript witness,
    // and the dialog queue is popped in-page by the dialog-respond JS, not by a
    // Swift pop helper).

    // `v2PNGData` and `bestEffortPruneTemporaryFiles` moved to
    // `BrowserControlService` in `CmuxBrowser` (Control/BrowserControlService+Screenshot.swift)
    // as `pngData(from:)` / `persistScreenshot(imageData:surfaceId:)`; the
    // `browser.screenshot` witness forwards into the held `v2BrowserControl`.

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
        guard let selectorRaw = browserAutomation.selector(in: params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }

        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let browserPanel = ctx.browserPanel
            guard let selector = browserAutomation.resolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = scriptBuilder(v2JSONLiteral(selector))
            let retryAttempts = max(1, v2Int(params, "retry_attempts") ?? 3)
            // Pure script assembly lives in `BrowserControlService` (CmuxBrowser),
            // shared with the `v2BrowserWait` resolved-selector branch; the WebKit
            // evaluation in `v2WaitForBrowserCondition` below stays on the worker lane.
            let selectorCondition = v2BrowserControl.waitSelectorPresentScript(selector: selector)

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

            // The in-page DOM-walk script is built by CmuxBrowser's
            // ``BrowserControlService/snapshotScript(interactiveLiteral:cursorLiteral:compactLiteral:maxDepth:scopeLiteral:)``;
            // only the byte-identical script assembly moved there. The WebKit
            // evaluation, element-ref allocation, and tree-line/payload shaping
            // stay here on the socket-worker lane.
            let script = v2BrowserControl.snapshotScript(
                interactiveLiteral: interactiveLiteral,
                cursorLiteral: cursorLiteral,
                compactLiteral: compactLiteral,
                maxDepth: maxDepth,
                scopeLiteral: scopeLiteral
            )

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

                    let refToken = browserAutomation.allocateElementRef(surfaceId: surfaceId, selector: selector)
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
        let selectorRaw = browserAutomation.selector(in: params)

        // The condition expressions are built by CmuxBrowser's
        // ``BrowserControlService`` wait-script builders; only the byte-identical
        // string assembly moved there. The param-precedence resolution
        // (url_contains > text_contains > load_state > function > default) stays
        // here, exactly as before.
        let conditionScriptBase: String = {
            if let urlContains = v2String(params, "url_contains") {
                return v2BrowserControl.waitURLContainsScript(substring: urlContains)
            }
            if let textContains = v2String(params, "text_contains") {
                return v2BrowserControl.waitTextContainsScript(substring: textContains)
            }
            if let loadState = v2String(params, "load_state") {
                let normalizedLoadState = loadState.lowercased()
                if normalizedLoadState == "interactive" {
                    return v2BrowserControl.waitLoadStateInteractiveScript()
                }
                return v2BrowserControl.waitLoadStateScript(normalizedLoadState: normalizedLoadState)
            }
            if let fn = v2String(params, "function") {
                return v2BrowserControl.waitFunctionScript(function: fn)
            }
            return v2BrowserControl.waitDefaultReadyScript()
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
            guard let selector = browserAutomation.resolveSelector(selectorRaw, surfaceId: surfaceIdOut) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            conditionScript = v2BrowserControl.waitSelectorPresentScript(selector: selector)
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
            v2BrowserControl.getTextScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserGetHTML(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.html") { selectorLiteral in
            v2BrowserControl.getHTMLScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserGetValue(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "get.value") { selectorLiteral in
            v2BrowserControl.getValueScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserGetAttr(params: [String: Any]) -> V2CallResult {
        guard let attr = v2String(params, "attr") ?? v2String(params, "name") else {
            return .err(code: "invalid_params", message: "Missing attr/name", data: nil)
        }
        return v2BrowserSelectorAction(params: params, actionName: "get.attr") { selectorLiteral in
            v2BrowserControl.getAttrScript(selectorLiteral: selectorLiteral, attrLiteral: v2JSONLiteral(attr))
        }
    }

    private nonisolated func v2BrowserGetCount(params: [String: Any]) -> V2CallResult {
        guard let selectorRaw = browserAutomation.selector(in: params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        return v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            guard let selector = browserAutomation.resolveSelector(selectorRaw, surfaceId: surfaceId) else {
                return .err(code: "not_found", message: "Element reference not found", data: ["selector": selectorRaw])
            }
            let script = v2BrowserControl.getCountScript(selectorLiteral: v2JSONLiteral(selector))
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
            v2BrowserControl.getBoxScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserGetStyles(params: [String: Any]) -> V2CallResult {
        let property = v2String(params, "property")
        return v2BrowserSelectorAction(params: params, actionName: "get.styles") { selectorLiteral in
            if let property {
                return v2BrowserControl.getStylesPropertyScript(
                    selectorLiteral: selectorLiteral,
                    propertyLiteral: v2JSONLiteral(property)
                )
            }
            return v2BrowserControl.getStylesSummaryScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserIsVisible(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.visible") { selectorLiteral in
            v2BrowserControl.isVisibleScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserIsEnabled(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.enabled") { selectorLiteral in
            v2BrowserControl.isEnabledScript(selectorLiteral: selectorLiteral)
        }
    }

    private nonisolated func v2BrowserIsChecked(params: [String: Any]) -> V2CallResult {
        v2BrowserSelectorAction(params: params, actionName: "is.checked") { selectorLiteral in
            v2BrowserControl.isCheckedScript(selectorLiteral: selectorLiteral)
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

    /// Resolves one `browser.get.*` / `browser.is.*` getter or
    /// `browser.eval` / `browser.snapshot` / `browser.wait` eval-result query
    /// request by running the co-located legacy body and carrying its
    /// `V2CallResult` pre-shaped.
    ///
    /// Byte-faithful to the former `v2BrowserJSCommandOnSocketWorker` dispatch for
    /// these methods: each case calls the identical `v2BrowserGet*` / `v2BrowserIs*`
    /// / `v2BrowserEval` / `v2BrowserSnapshot` / `v2BrowserWait` body with the
    /// Foundation-bridged params, and `controlBridge` maps the resulting payload to
    /// the package's typed `ControlCallResult`. The bodies stay app-side because
    /// they reach the shared `v2BrowserSelectorAction` retry loop (still shared with
    /// the `browser.*` interaction commands), the `v2BrowserWithPanelContext` panel
    /// read + `querySelectorAll` read (`get.count`), the `v2RunBrowserJavaScript`
    /// WebKit evaluation seam (`eval`/`snapshot`/`wait`), and the `v2BrowserControl`
    /// scripts substrate, none of which this control package may import.
    ///
    /// `get.attr` re-reads and re-validates `attr`/`name` inside `v2BrowserGetAttr`
    /// identically to the worker's guard, so passing the validated request straight
    /// through preserves the legacy missing-param branch exactly (the worker's guard
    /// and the body's guard are the same trimmed-non-empty check). `eval` re-reads
    /// and re-validates its required `script` leaf inside `v2BrowserEval` (the worker
    /// carries `eval` params verbatim with no pre-check), preserving the
    /// `Missing script` `invalid_params` branch exactly as the base dispatch did.
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
        case let .eval(params):
            return controlBridge(v2BrowserEval(params: foundationParams(params)))
        case let .snapshot(params):
            return controlBridge(v2BrowserSnapshot(params: foundationParams(params)))
        case let .wait(params):
            return controlBridge(v2BrowserWait(params: foundationParams(params)))
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
            guard let selector = browserAutomation.resolveSelector(rawSelector, surfaceId: ctx.surfaceId) else {
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
        let ref = browserAutomation.allocateElementRef(surfaceId: ctx.surfaceId, selector: selector)
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
                v2BrowserControl.highlightScript(selectorLiteral: selectorLiteral)
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
        let selectorRaw = browserAutomation.selector(in: params)

        var success: ControlBrowserPanelActionSuccess?
        let panelResult = v2BrowserWithPanelContext(params: params) { ctx in
            let surfaceId = ctx.surfaceId
            let selector = selectorRaw.flatMap { browserAutomation.resolveSelector($0, surfaceId: surfaceId) }
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
            let script = v2BrowserControl.dialogRespondScript(
                acceptLiteral: acceptLiteral,
                textLiteral: textLiteral
            )

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = browserAutomation.pendingDialogWireDicts(surfaceId: surfaceId)
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
    /// because it mutates the per-surface frame-selector state (read by the
    /// out-of-scope worker-lane JS-eval methods).
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
            guard let selector = browserAutomation.resolveSelector(rawSelector, surfaceId: surfaceId) else {
                return .elementRefNotFound(rawSelector: rawSelector)
            }
            let script = v2BrowserControl.frameSelectProbeScript(selectorLiteral: v2JSONLiteral(selector))
            switch v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                if let dict = value as? [String: Any],
                   let ok = dict["ok"] as? Bool,
                   ok {
                    v2BrowserSurfaceState.setFrameSelector(selector, surfaceId: surfaceId)
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
    /// because it mutates the per-surface frame-selector state (read by the
    /// out-of-scope worker-lane JS-eval methods).
    func controlBrowserFrameMain(
        params: [String: JSONValue]
    ) -> ControlBrowserFrameMainResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            v2BrowserSurfaceState.clearFrameSelector(surfaceId: resolved.surfaceId)
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
    /// the identity payload + `png_base64`/`path`/`url` keys. The stateless PNG
    /// encode and temp-file persistence moved to
    /// `BrowserControlService.pngData(from:)` /
    /// `BrowserControlService.persistScreenshot(imageData:surfaceId:)` in
    /// `CmuxBrowser`; this witness stays on `TerminalController` because it calls
    /// the `private` `v2AwaitCallback` blocking-await plumbing and
    /// `BrowserPanel.captureAutomationVisibleViewportSnapshot` (the WebKit seam).
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
                    finish(self.v2BrowserControl.pngData(from: image))
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
        let persistence = v2BrowserControl.persistScreenshot(imageData: imageData, surfaceId: surfaceId)

        return .resolved(
            workspaceID: resolved.workspace.id,
            surfaceID: surfaceId,
            pngBase64: pngBase64,
            filePath: persistence.filePath,
            fileURL: persistence.fileURL
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
            switch BrowserDownloadFileWaiter().wait(forDownloadAt: path, timeout: timeout) {
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

        guard let downloadEvent = browserAutomation.waitForDownloadEvent(surfaceId: snapshot.surfaceId, timeout: timeout) else {
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
                    ? browserAutomation.popDownloadEvent(surfaceId: surfaceId)
                    : nil,
                error: nil
            )
        }
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
            switch BrowserImportScope.from(rawToken: v2String(foundation, "scope")) {
            case .empty:
                return .scopeEmpty
            case .invalid:
                return .scopeInvalid
            case .scope(let resolved):
                scope = resolved
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

    /// `browser.addinitscript` witness (``ControlBrowserContext``): registers a
    /// document-start init script on the resolved browser and evaluates it once,
    /// byte-faithful to the former `v2BrowserAddInitScript(params:)` body. The
    /// coordinator emits the `Missing script` param error before this runs and
    /// shapes the identity payload plus `scripts` count. Stays on
    /// `TerminalController` (not the cookies/storage context file) because it
    /// mutates the per-surface init-script state, which the surface-teardown
    /// cleanup also reaches.
    func controlBrowserAddInitScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddInitScriptResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let scriptCount = v2BrowserSurfaceState.appendInitScript(script, surfaceId: resolved.surfaceId)

            let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            resolved.browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script, timeout: 10.0)

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                scriptCount: scriptCount
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
    /// Stays on `TerminalController` because it mutates the per-surface init-style
    /// state, which surface teardown also reaches.
    func controlBrowserAddStyle(
        params: [String: JSONValue],
        css: String
    ) -> ControlBrowserAddStyleResolution {
        switch browserResolvePanelTyped(params: params.mapValues(\.foundationObject)) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let styleCount = v2BrowserSurfaceState.appendInitStyle(css, surfaceId: resolved.surfaceId)

            let cssLiteral = v2JSONLiteral(css)
            let source = v2BrowserControl.addStyleScript(cssLiteral: cssLiteral)

            let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            resolved.browserPanel.webView.configuration.userContentController.addUserScript(userScript)
            _ = v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: source, timeout: 10.0)

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                styleCount: styleCount
            )
        }
    }

    // browser.viewport.set / browser.geolocation.set / browser.offline.set /
    // browser.trace.start / browser.trace.stop / browser.network.route /
    // browser.network.unroute / browser.network.requests /
    // browser.screencast.start / browser.screencast.stop / browser.input_mouse /
    // browser.input_keyboard / browser.input_touch moved to
    // ControlCommandCoordinator.handleBrowserUnsupported (CmuxControlSocket).
    // The per-surface unsupported-network-request log lives in the
    // `v2BrowserSurfaceState` automation store (CmuxBrowser), cleared on surface
    // teardown; the coordinator records into / reads it via
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

#endif

    // `responderChainContains(_:target:)` relocated onto its owning type as
    // ``CmuxFoundation/NSResponder/responderChain(contains:)``; the synthetic-input
    // and browser-focus paths now walk the chain through that single helper
    // (`start?.responderChain(contains:) ?? false`).

    // The v1 `set_app_focus` / `simulate_app_active` bodies moved onto
    // ControlCommandCoordinator: the token table + dispatch live in
    // `handleSurfaceSendNotifyV1`, and the `AppFocusState` write /
    // `applicationDidBecomeActive` re-run resolve through the existing
    // ``ControlAppFocusContext`` witnesses
    // (`TerminalController+ControlAppFocusContext.swift`).

    // `parseSplitDirection` relocated onto its owning type as the failable
    // initializer ``CmuxPanes/SplitDirection/init(controlToken:)``; the control
    // socket, command palette, project, and move-tab paths now resolve a
    // direction token through that single source of truth.

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

    // The file-private `viewDepth(of:maxDepth:)` and `isPortalHosted(_:)`
    // surface-health helpers were dead in this file: their only live use was the
    // sidebar surface-health row, which already owns byte-faithful twins
    // (`controlSidebarViewDepth` / `controlSidebarIsPortalHosted`) in
    // `TerminalController+ControlSidebarContext3.swift`. Removed here as the
    // last step of relocating the surface-health walk to that conformance.

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

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        // `classify` drives the UUID parse lazily and short-circuits, so `v2UUID`
        // (a main-actor hop + control-handle lookup for non-UUID strings) runs in
        // the original loop's order and never for keys past a short-circuit. The
        // presence check stays eager because it is a pure dict read.
        let reads = ["surface_id", "terminal_id", "tab_id"].map { key -> MobileTerminalAliasUUID.Read in
            MobileTerminalAliasUUID.Read(
                present: v2HasNonNullParam(params, key),
                resolveUUID: { self.v2UUID(params, key) }
            )
        }
        return MobileTerminalAliasUUID.classify(reads)
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
            // which observes the workspace list (`workspaces.tabs`) directly.
            // Don't fire here.
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
        // The captured-download observer is owned and removed by
        // `browserAutomation` (CmuxBrowser) in its own deinit.
        //
        // No stop() here: the controller is an app-lifetime singleton, so
        // deinit never runs; listener teardown is applicationWillTerminate's
        // synchronous stop() on the main actor.
    }
}
