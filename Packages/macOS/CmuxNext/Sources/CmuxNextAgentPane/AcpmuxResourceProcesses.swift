public import CmuxNextMetrics
public import CmuxNextWakeups

/// acpmux and its agent hosts as processes of a resource sample (p09-observability-121): the daemon's pid from its own
/// `_acpmux/status`, each agent host's from its record under a held liveness lock (``AcpmuxQuitProof/liveHostPIDs(home:)``).
/// Never a scan of process names, and it never starts a daemon. The app's acpmux environment is resolved once, at the
/// first ask, on the files lane (it checks the executable's signature).
public actor AcpmuxResourceProcesses {
    private let work: BackgroundWork
    private let resolve: @Sendable () -> AcpmuxEnvironment?
    private var environment: AcpmuxEnvironment?
    private var isResolved = false

    /// - Parameters:
    ///   - work: Runs the resolve and the record reads (lane `files`).
    ///   - resolve: The app's acpmux environment; nil without one. Blocking: it runs on the lane.
    public init(work: BackgroundWork, resolve: @escaping @Sendable () -> AcpmuxEnvironment?) {
        self.work = work
        self.resolve = resolve
    }

    /// acpmux and its live agent hosts now: empty when no daemon answers; nil when the lane did not run (quit).
    public func processes() async -> [ProcessResourceSampler.KnownProcess]? {
        if !isResolved {
            let resolve = resolve
            do {
                environment = try await work.run(.bestEffort, mayBlock: .files) { resolve() }
            } catch {
                return nil
            }
            isResolved = true
        }
        guard let environment, let pid = await environment.daemonPID() else { return [] }
        let home = environment.home
        let hosts = (try? await work.run(.bestEffort, mayBlock: .files) { AcpmuxQuitProof.liveHostPIDs(home: home) }) ?? []
        return [ProcessResourceSampler.KnownProcess(kind: .acpmux, pid: pid)]
            + hosts.map { ProcessResourceSampler.KnownProcess(kind: .agentHost, pid: $0) }
    }
}
