/// Decides which execution lane a v2 method runs on (was the
/// `socketWorkerV2Methods` tables + `executionPolicy(forV2Method:)` on
/// `TerminalController`).
public struct ControlMethodRoutingPolicy: Sendable {
    /// Methods that run on the socket-worker thread instead of the main actor.
    private static let socketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "auth.status",
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
        "system.top",
        "system.memory",
        "workspace.remote.pty_sessions",
        "workspace.remote.pty_close",
        "workspace.remote.pty_detach",
        "workspace.remote.pty_bridge",
        "workspace.remote.pty_resize",
        "sidebar.custom.validate",
        "sidebar.custom.reload",
        "sidebar.custom.select",
        // debug.sidebar.simulate_drag intentionally runs on the socket worker
        // so its Thread.sleep between drag-state ticks doesn't block the main
        // actor (which still owns the SidebarDragState mutations via
        // v2MainSync). Running on .mainActor would deadlock the UI for the
        // entire simulation, defeating the profiling workload.
        "debug.sidebar.simulate_drag",
    ]

    /// Socket-worker methods that are also safe to invoke from the main
    /// thread (pure, non-blocking probes).
    private static let mainThreadCallableSocketWorkerMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
    ]

    /// Creates a routing policy.
    public init() {}

    /// The execution lane for a method: every `vm.`-prefixed method and the
    /// fixed socket-worker set run on the worker; everything else runs on the
    /// main actor.
    ///
    /// - Parameter method: The trimmed method name.
    /// - Returns: The execution policy.
    public func executionPolicy(forMethod method: String) -> ControlCommandExecutionPolicy {
        if method.hasPrefix("vm.") || Self.socketWorkerMethods.contains(method) {
            return .socketWorker
        }
        return .mainActor
    }

    /// Whether a socket-worker method may also be invoked from the main
    /// thread.
    ///
    /// - Parameter method: The trimmed method name.
    /// - Returns: `true` for the main-thread-callable subset.
    public func isMainThreadCallable(method: String) -> Bool {
        Self.mainThreadCallableSocketWorkerMethods.contains(method)
    }
}
