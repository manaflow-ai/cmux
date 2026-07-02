/// Where a control command executes (was `SocketCommandExecutionPolicy` +
/// the `socketWorkerV2Methods`/`mainThreadCallableSocketWorkerV2Methods`
/// tables on `TerminalController`). `init(forMethod:)` classifies v2 methods;
/// `init(forV1Command:)` classifies v1 space-delimited commands.
///
/// An isolation-intent value: the dispatcher consults it to decide whether a
/// method runs on the main actor or stays on the socket-worker thread. The
/// main-thread-callable refinement only exists for worker-lane methods, so it
/// is an associated value of that case rather than a separate table.
public enum ControlCommandExecutionPolicy: Sendable, Equatable {
    /// The command must run on the main actor (UI/window/workspace state).
    case mainActor
    /// The command runs on the socket-worker thread (blocking or long-running
    /// work that must not occupy the main actor). `mainThreadCallable` marks
    /// the pure, non-blocking probes that may also be invoked synchronously
    /// from the main thread.
    case socketWorker(mainThreadCallable: Bool)

    /// Classifies a method: every `vm.`- and `remotes.`-prefixed method and the
    /// fixed socket-worker set run on the worker; everything else runs on the
    /// main actor.
    ///
    /// `remotes.*` (the `cmux remotes` device-registry verbs) make blocking,
    /// authenticated web API calls just like `vm.*`, so they must stay off the
    /// main actor; a prefix match keeps the three verbs in lockstep without
    /// listing each.
    ///
    /// - Parameter method: The trimmed method name.
    public init(forMethod method: String) {
        if method.hasPrefix("vm.") || method.hasPrefix("remotes.")
            || Self.socketWorkerMethods.contains(method) {
            self = .socketWorker(
                mainThreadCallable: Self.mainThreadCallableSocketWorkerMethods.contains(method)
            )
        } else {
            self = .mainActor
        }
    }

    /// Classifies a v1 (space-delimited) command: the fixed worker-lane set
    /// runs on the socket-worker thread; everything else runs on the main
    /// actor.
    ///
    /// The v2 namespace prefix rules (`vm.`, `remotes.`) deliberately do not
    /// apply here — they are v2 method namespaces, and a v1 token that happens
    /// to contain a dot must not be routed off the main lane by accident.
    ///
    /// - Parameter command: The v1 command token, lowercased by the dispatcher
    ///   (`processCommand` lowercases before dispatching, and this initializer
    ///   expects the same normalization).
    public init(forV1Command command: String) {
        if Self.socketWorkerV1Commands.contains(command) {
            self = .socketWorker(
                mainThreadCallable: Self.mainThreadCallableSocketWorkerV1Commands.contains(command)
            )
        } else {
            self = .mainActor
        }
    }

    /// True when the command runs on the socket-worker thread.
    public var runsOnSocketWorker: Bool {
        if case .socketWorker = self { return true }
        return false
    }

    /// Methods that run on the socket-worker thread instead of the main actor.
    private static let socketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "auth.status",
        "auth.sign_in_url",
        "auth.begin_sign_in",
        "auth.sign_out",
        "feedback.submit",
        "feed.push",
        "feed.permission.reply",
        "feed.question.reply",
        "feed.exit_plan.reply",
        "browser.download.wait",
        "browser.profiles.list",
        "browser.profiles.create",
        "browser.profiles.rename",
        "browser.profiles.clear",
        "browser.profiles.delete",
        "browser.import.cookies",
        "mobile.attach_ticket.create",
        // `mobile.terminal.set_font` only validates params and emits a
        // `terminal.set_font` push event via thread-safe MobileHostService
        // statics (no main-actor UI access), so it runs on the socket worker
        // like the other mobile data-plane verbs. Without this entry the policy
        // routes it to the main-actor processV2Command switch, which lacks the
        // case, and the control socket returns method_not_found.
        "mobile.terminal.set_font",
        "system.top",
        "system.memory",
        // `workspace.env` is a read that resolves a workspace and copies its
        // env dictionary behind a `v2MainSync` hop, so it runs on the worker
        // lane like the other workspace reads below.
        "workspace.env",
        "workspace.remote.pty_sessions",
        "workspace.remote.pty_close",
        "workspace.remote.pty_detach",
        "workspace.remote.pty_bridge",
        "workspace.remote.pty_resize",
        "remote.tmux.sessions",
        "remote.tmux.attach",
        "remote.tmux.detach",
        "remote.tmux.state",
        "remote.tmux.mirror",
        "remote.tmux.window",
        "sidebar.custom.validate",
        "sidebar.custom.reload",
        "sidebar.custom.select",
        "sidebar.custom.open",
        // debug.sidebar.simulate_drag intentionally runs on the socket worker
        // so its Thread.sleep between drag-state ticks doesn't block the main
        // actor (which still owns the SidebarDragState mutations via
        // v2MainSync). Running on .mainActor would deadlock the UI for the
        // entire simulation, defeating the profiling workload.
        "debug.sidebar.simulate_drag",
        // Browser automation methods that wait on page JavaScript, WebKit
        // cookies, or capture callbacks run on the socket worker: on the main
        // actor they block SwiftUI updates for their full duration, and on a
        // not-yet-mounted webview that is a starvation deadlock (the JS can't
        // run until SwiftUI mounts the webview, which can't happen while the
        // handler holds the main thread). UI/model access inside the handlers
        // stays on main via v2MainSync.
        "browser.navigate",
        "browser.back",
        "browser.forward",
        "browser.reload",
        "browser.snapshot",
        "browser.eval",
        "browser.wait",
        "browser.click",
        "browser.dblclick",
        "browser.hover",
        "browser.focus",
        "browser.type",
        "browser.fill",
        "browser.press",
        "browser.keydown",
        "browser.keyup",
        "browser.check",
        "browser.uncheck",
        "browser.select",
        "browser.scroll",
        "browser.scroll_into_view",
        "browser.get.text",
        "browser.get.html",
        "browser.get.value",
        "browser.get.attr",
        "browser.get.count",
        "browser.get.box",
        "browser.get.styles",
        "browser.is.visible",
        "browser.is.enabled",
        "browser.is.checked",
        "browser.find.role",
        "browser.find.text",
        "browser.find.label",
        "browser.find.placeholder",
        "browser.find.alt",
        "browser.find.title",
        "browser.find.testid",
        "browser.find.first",
        "browser.find.last",
        "browser.find.nth",
        "browser.highlight",
        "browser.screenshot",
        "browser.frame.select",
        "browser.dialog.accept",
        "browser.dialog.dismiss",
        "browser.cookies.get",
        "browser.cookies.set",
        "browser.cookies.clear",
        "browser.storage.get",
        "browser.storage.set",
        "browser.storage.clear",
        "browser.console.list",
        "browser.console.clear",
        "browser.errors.list",
        "browser.state.save",
        "browser.state.load",
        "browser.addinitscript",
        "browser.addscript",
        "browser.addstyle",
    ]

    /// Socket-worker methods that are also safe to invoke from the main
    /// thread (pure, non-blocking probes).
    private static let mainThreadCallableSocketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
    ]

    /// v1 commands that run on the socket-worker thread instead of the main
    /// actor. Only `ping` for now (the dispatcher's former hard-coded fast
    /// path); the v1 telemetry commands migrate here tranche by tranche as
    /// their worker-lane bodies land.
    private static let socketWorkerV1Commands: Set<String> = [
        "ping",
    ]

    /// Worker-lane v1 commands that are also safe to invoke from the main
    /// thread (pure, non-blocking probes). Must be a subset of
    /// ``socketWorkerV1Commands``.
    private static let mainThreadCallableSocketWorkerV1Commands: Set<String> = [
        "ping",
    ]
}
