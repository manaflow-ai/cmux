public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): one `cmux carrier serve` child for the
/// session (``CloudCarrierServe``), whose private socket dials the machine's `mux` once per connection, the
/// way the old link socket did. Every client of the machine's daemon gets that socket: the daemon
/// connection, the CLI's copies, moves, uploads and updates, and the phone. The owner answer is the
/// machine record's: its creator is the caller.
public struct CloudCarrierResolver: CloudLinkResolver {
    private let serve: CloudCarrierServe?
    private let ownership: @Sendable () async -> CloudCallerOwnership

    /// `serve`: nil when the app has no bundled CLI (every connect then fails as the helper not running).
    /// `ownership`: the signed-in caller and the machine, read at each connect.
    public init(serve: CloudCarrierServe?, ownership: @escaping @Sendable () async -> CloudCallerOwnership) {
        self.serve = serve
        self.ownership = ownership
    }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        guard let serve else { throw CloudLinkError.helperNotRunning(reason: "no bundled cmux-tui") }
        // Each connect starts a fresh child: its environment's access token is read as it starts.
        let socket = try await serve.socketPath(fresh: true)
        // TODO(carrier): read "vmk":"owner"|"team" from the dial's ok line once the carrier sends it.
        let caller = await ownership()
        return CloudLinkSocket(key: key, path: socket, generation: nil, callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
    }

    /// Ends the session's `carrier serve` (machine removed, sign-out, quit).
    public func close(_ key: CloudLinkKey) async { await serve?.stop() }
}

/// One Cloud session's `cmux carrier serve --machine <vm_id> --socket <path>`: started on the first
/// connect, kept for the session, stopped by closing its stdin (it then removes its socket and exits).
/// A child that ended is started again only once it has exited, so two never hold the same socket.
public actor CloudCarrierServe {
    /// `carrier serve` binds at once and dials only per connection, so its ready line comes fast.
    static let readyDeadline: Duration = .seconds(15)
    private let connector: CloudCarrierDial.Connector
    private let socket: String
    private let check: @Sendable (String) throws -> Void
    private var child: ChildProcess?
    private var ready = false
    private var starting: Task<String, any Error>?

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which ``CloudLinkSocketPolicy`` checks once the child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine)) { try CloudLinkSocketPolicy.check($0) }
    }

    init(connector: CloudCarrierDial.Connector, socket: String, check: @escaping @Sendable (String) throws -> Void) {
        (self.connector, self.socket, self.check) = (connector, socket, check)
    }

    /// The serving socket, starting the child when none runs, or anew (after the old one exits) when `fresh`.
    /// Throws ``CloudLinkError`` when it does not get ready.
    public func socketPath(fresh: Bool = false) async throws -> String {
        if let starting { return try await starting.value }
        if fresh { stop() } else if ready, child?.isRunning == true { return socket }
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Closes the child's stdin: it removes its socket and exits.
    public func stop() {
        ready = false
        child?.closeInput()
    }

    private func launch() async throws -> String {
        if let previous = child { _ = await previous.waitForExit() }
        ready = false
        let environment = ProcessInfo.processInfo.environment.merging(try await connector.environment()) { $1 }
        let child = ChildProcess(executable: connector.cli, arguments: connector.dial.serveArguments(socket: socket), environment: environment)
        self.child = child
        do {
            try child.startHoldingInput()
            let served = try await child.firstLine(within: Self.readyDeadline, label: "cmux carrier serve", stderr: true) { CloudCarrierDial.readySocket($0) }
            guard served == socket else { throw CloudLinkError.invalidAnswer("served another socket") }
            try check(served)
        } catch {
            child.closeInput()
            throw (error as? CloudLinkError) ?? CloudLinkError.helperNotRunning(reason: String(describing: error))
        }
        ready = true
        return socket
    }
}

extension CloudCallerOwnership {
    /// The record's rule (cloud-machine-ops.ts `CloudVmKind`): the machine's creator is its `owner`, any
    /// other member of its team is `team`; unknown while either id is missing.
    public init(creator: String?, caller: String?) {
        guard let creator, let caller, !creator.isEmpty, !caller.isEmpty else { self = .unknown; return }
        self = creator == caller ? .owner : .team
    }
}
