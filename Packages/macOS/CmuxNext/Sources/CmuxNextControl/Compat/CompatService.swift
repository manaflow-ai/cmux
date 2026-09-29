public import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Synchronization

/// The old `cmux` CLI's v2 and v1 verbs on top of cmux-tui and the App
/// (plans/cmux-next/cli-compat.md), registered on the `ControlRouter`.
///
/// Lanes (architecture.md 5a):
/// - reads (`*.list`, `*.current`, `system.tree`, `system.identify`, …)
///   are `snapshot` methods: they answer off the main actor from the
///   published `ControlSnapshot` topology and never wait;
/// - daemon verbs (create, split, send, read-screen, close, rename, …) are
///   `async` methods: off the main actor under the request deadline, sent
///   straight to cmux-tui (the serialization point). Creation verbs read a
///   fresh `list-workspaces` so they can report what they made;
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
    /// cmux keys every terminal this app spawns gets (`LaunchIdentity.terminalEnvironment`).
    let terminalEnvironment: [String: String]
    private let routerRef = Mutex(WeakRouter())

    var router: ControlRouter? { routerRef.withLock { $0.router } }
    var identity: ControlIdentity {
        router?.identity ?? ControlIdentity(version: "0", build: "0", bundleID: nil, tag: nil, processID: getpid())
    }

    public init(frontend: any CompatFrontend, terminalEnvironment: [String: String] = [:],
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
                methods.append(.snapshot(name) { control in
                    try body(CompatCall(service: self, control: control))
                })
            case .async(let body):
                methods.append(.async(name) { control in
                    try await body(CompatCall(service: self, control: control))
                })
            }
        }
        for name in CompatUnsupported.methods.keys.sorted() where Self.handlers[name] == nil {
            let reason = CompatUnsupported.methods[name] ?? "not implemented"
            methods.append(.snapshot(name) { _ in throw CompatErrors.unsupported(reason, method: name) })
        }
        router.register(methods)
        router.registerUnknownMethod { name in Self.unsupportedError(for: name) }
        // The router owns the service through these closures; the service
        // holds the router weakly, so there is no cycle.
        router.registerV1 { line in await CompatV1.respond(line, service: self) }
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

    /// The world as of the router's published snapshot (v1 verbs, which
    /// have no `ControlCall`).
    func world() async throws -> CompatWorld {
        guard let router else { throw CompatErrors.stopped }
        let topology = router.snapshots.current.topology
        guard topology.isLoaded else {
            throw ControlError(code: "unavailable", message: "cmux-next has not loaded the cmux-tui tree yet (daemon \(topology.daemonState))")
        }
        return CompatWorld(topology: topology, refs: refs)
    }

    func connection() throws -> DaemonConnection {
        guard let connection = connectionProvider() else { throw CompatErrors.notConnected }
        return connection
    }

    /// Runs one daemon command with the control-plane deadline and maps errors.
    func daemon<T: Sendable>(_ what: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> T) async throws -> T {
        let connection = try connection()
        do {
            return try await CompatDeadline.run(what) { try await body(connection) }
        } catch {
            throw CompatErrors.from(error, doing: what)
        }
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
