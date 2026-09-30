public import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Synchronization

/// The old `cmux` CLI's v2 and v1 verbs on top of cmux-tui and the App
/// (plans/cmux-next/cli-compat.md), registered on the `ControlRouter`.
///
/// Lanes (architecture.md 5a):
/// - reads (`*.list`, `*.current`, `system.tree`, `system.identify`, …)
///   answer off the main actor from the published `ControlSnapshot`
///   topology. They never ask the daemon: a read waits only until the
///   snapshot reflects every compat write acknowledged before it
///   (`CompatWriteBarrier`), normally zero or one frame;
/// - daemon verbs (create, split, send, read-screen, close, rename, …) are
///   `async` methods: off the main actor under the request deadline, sent
///   straight to cmux-tui (the serialization point). Creation verbs diff
///   barrier-fresh snapshots so they can report what they made;
/// - app-local changes (show a workspace, focus a pane, select a tab,
///   windows) hop through the router's bounded `MainActorWorkQueue`.
/// Every other old method answers a typed `unsupported` error.
public final class CompatService: Sendable {
    public typealias ConnectionProvider = @Sendable () -> DaemonConnection?

    let connectionProvider: ConnectionProvider
    let frontend: any CompatFrontend
    let refs = CompatRefRegistry()
    let sidebar = CompatSidebarStore()
    /// `agent_journal_append` reply sequence (per app process; the daemon keeps no journal).
    let journal = CompatJournalSequence()
    /// Daemon event sequence at the last acknowledged compat write.
    let writes = CompatWriteBarrier()
    /// `env` for every terminal this app spawns: the login allowlist, the
    /// launch and Ghostty terminal identity, and Ghostty's shell integration.
    let terminalEnvironment: @Sendable () async -> [String: String]
    private let routerRef = Mutex(WeakRouter())

    var router: ControlRouter? { routerRef.withLock { $0.router } }
    var identity: ControlIdentity {
        router?.identity ?? ControlIdentity(version: "0", build: "0", bundleID: nil, tag: nil, processID: getpid())
    }

    public init(frontend: any CompatFrontend,
                terminalEnvironment: @escaping @Sendable () async -> [String: String] = TerminalEnvironment.shared(),
                connection: @escaping ConnectionProvider) {
        self.frontend = frontend
        self.terminalEnvironment = terminalEnvironment
        self.connectionProvider = connection
    }

    /// Registers every compat method and the v1 handler on `router`.
    public func install(on router: ControlRouter) {
        routerRef.withLock { $0.router = router }
        var methods: [ControlMethod] = []
        for (name, handler) in Self.handlers.sorted(by: { $0.key < $1.key }) {
            switch handler {
            case .read(let body):
                // Off the main actor like a snapshot method, but after the
                // write barrier: a read that follows a write sees it.
                methods.append(.async(name) { control in
                    let snapshot = await self.readSnapshot(deadline: control.deadline)
                    let fresh = ControlCall(request: control.request, snapshot: snapshot, connection: control.connection,
                                            deadline: control.deadline)
                    return try body(CompatCall(service: self, control: fresh))
                })
            case .async(let body):
                let method = ControlMethod.async(name) { control in
                    try await body(CompatCall(service: self, control: control))
                }
                // Creation verbs wait for the terminal they start.
                methods.append(Self.terminalCreationMethods.contains(name)
                    ? method.withDeadline(.perRequest { request, _ in CompatCreate.startsTerminal(request.params) })
                    : method)
            }
        }
        for name in CompatUnsupported.methods.keys.sorted() where Self.handlers[name] == nil {
            let reason = CompatUnsupported.methods[name] ?? ControlStrings.text("control.error.notImplemented", "not implemented")
            methods.append(.snapshot(name) { _ in throw CompatErrors.unsupported(reason, method: name) })
        }
        router.register(methods)
        router.registerUnknownMethod { name in Self.unsupportedError(for: name) }
        // The router owns the service through these closures; the service
        // holds the router weakly, so there is no cycle.
        router.registerV1 { line in await CompatV1.respond(line, service: self) }
        router.registerTargetResolver { ref, deadline in try await self.resolveActionTarget(ref, deadline: deadline) }
    }

    /// Calls `handler` with a workspace UUID (the old app's form of its key)
    /// whenever a hook's `set_status`/`clear_status`/`set_progress` changes it.
    public func observeSidebarStatus(_ handler: @escaping @Sendable (String) -> Void) {
        sidebar.observe(handler)
    }

    /// The sidebar row's status line for a workspace UUID: its statuses by
    /// priority (`set_status` values, `icon value` when an icon is set), then
    /// the progress label, joined by " · ". Nil when there is nothing to show.
    public func sidebarStatusLine(workspace uuid: String) -> String? {
        let entry = sidebar.workspace(uuid)
        var parts = CompatV1Sidebar.sortedStatuses(entry).map { $0.status.value }.filter { !$0.isEmpty }
        if let progress = entry.progress {
            parts.append(progress.label.flatMap { $0.isEmpty ? nil : $0 } ?? "\(Int((progress.value * 100).rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Typed error for an unregistered method in an old namespace, for the
    /// router's unknown-method path (see `CompatUnsupported.reason(for:)`).
    public static func unsupportedError(for method: String) -> ControlError? {
        CompatUnsupported.reason(for: method).map { CompatErrors.unsupported($0, method: method) }
    }

    /// Verbs that can start a terminal and answer after it exists.
    static let terminalCreationMethods: Set<String> = ["surface.create", "surface.split", "pane.create", "workspace.create"]

    static let handlers: [String: CompatHandler] = {
        var all: [String: CompatHandler] = [:]
        for table in [CompatSystemMethods.table, CompatWorkspaceMethods.table, CompatPaneMethods.table,
                      CompatSurfaceMethods.table, CompatTerminalMethods.table, CompatNotificationMethods.table,
                      CompatAgentMethods.table, CompatBrowserMethods.table, CompatFeed.table] {
            all.merge(table) { first, _ in first }
        }
        return all
    }()

    // MARK: - Shared plumbing

    /// How long a read waits for the snapshot to pass the write barrier.
    static let barrierWait: Duration = .seconds(1)
    /// Request time kept for the `list-workspaces` fallback after a missed barrier.
    static let fallbackReserve: Duration = .milliseconds(500)

    /// A snapshot that reflects every compat write acknowledged so far, or
    /// the current one when the tree has not loaded or the barrier was not
    /// reached in time. Never asks the daemon.
    func readSnapshot(deadline: ContinuousClock.Instant) async -> ControlSnapshot {
        guard let snapshots = router?.snapshots else { return .empty }
        return await barrierSnapshot(snapshots, deadline: deadline) ?? snapshots.current
    }

    private func barrierSnapshot(_ snapshots: ControlSnapshotStore, deadline: ContinuousClock.Instant) async -> ControlSnapshot? {
        let current = snapshots.current
        let barrier = writes.sequence
        if current.reflects(daemonSequence: barrier) { return current }
        guard current.topology.isLoaded else { return nil }
        let wait = min(deadline - Self.fallbackReserve, .now + Self.barrierWait)
        return await snapshots.snapshot(reflecting: barrier, deadline: wait)
    }

    /// The world for a compat verb: the published snapshot once it reflects
    /// every acknowledged compat write (read-your-writes, no daemon round
    /// trip). Only when the tree has not loaded or the store did not catch
    /// up in time (resync failed, reconnecting) does it read a fresh
    /// `list-workspaces`, joined with the snapshot's app-local state.
    func world(deadline: ContinuousClock.Instant = .now + CompatDeadline.controlPlane) async throws -> CompatWorld {
        guard let router else { throw CompatErrors.stopped }
        if let snapshot = await barrierSnapshot(router.snapshots, deadline: deadline) {
            return CompatWorld(topology: snapshot.topology, refs: refs)
        }
        let topology = router.snapshots.current.topology
        guard topology.isLoaded || connectionProvider() != nil else {
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.treeNotLoaded", "cmux-next has not loaded the cmux-tui tree yet (daemon %@)", "\(topology.daemonState)"))
        }
        let tree = try await daemon("list-workspaces", mutates: false) { try await $0.listWorkspaces() }
        return CompatWorld(topology: CompatFreshTopology.make(tree: tree, appState: router.snapshots.current.topology), refs: refs)
    }

    /// Raises the write barrier to everything the daemon connection routed so
    /// far. Call after a write's reply (or after the daemon work an action
    /// started finished).
    func noteWrite() async {
        guard let connection = connectionProvider(), let sequence = await connection.eventSequence() else { return }
        writes.raise(to: sequence)
    }

    func connection() throws -> DaemonConnection {
        guard let connection = connectionProvider() else {
            if let failure = router?.snapshots.current.topology.daemonFailure { throw CompatErrors.daemonUnavailable(failure) }
            throw CompatErrors.notConnected
        }
        return connection
    }

    /// Runs one daemon command with the control-plane deadline and maps
    /// errors. `mutates` commands (the default) change the tree, so later
    /// reads wait for their events (`noteWrite`); pass false for reads and
    /// for input that does not change the tree.
    func daemon<T: Sendable>(_ what: String, mutates: Bool = true,
                             _ body: @escaping @Sendable (DaemonConnection) async throws -> T) async throws -> T {
        let connection = try connection()
        let result: T
        do {
            result = try await CompatDeadline.run(what) { try await body(connection) }
        } catch {
            if mutates { await noteWrite() }
            throw CompatErrors.from(error, doing: what)
        }
        if mutates { await noteWrite() }
        return result
    }

    /// Runs an app-local change on the main actor through the bounded queue.
    @discardableResult
    func perform(_ intent: CompatFrontendIntent, connection: ControlConnectionID = .inProcess, method: String = "v1",
                 deadline: ContinuousClock.Instant = .now + CompatDeadline.controlPlane) async throws -> JSON {
        guard let router else { throw CompatErrors.stopped }
        let frontend = frontend
        return try await router.workQueue.run(connection: connection, method: method, deadline: deadline) {
            try frontend.perform(intent)
        }
    }
}

struct WeakRouter: Sendable {
    weak var router: ControlRouter?
}

/// A compat method body and its lane.
enum CompatHandler: Sendable {
    /// Answers from the snapshot; never waits.
    case read(@Sendable (CompatCall) throws -> JSON)
    /// Talks to cmux-tui or the App; the router bounds it by the request deadline.
    case async(@Sendable (CompatCall) async throws -> JSON)
}
