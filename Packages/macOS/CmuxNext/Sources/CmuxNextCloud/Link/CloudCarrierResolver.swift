public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): one `cmux carrier serve` child for the
/// session (``CloudCarrierServe``), whose private socket dials the machine's `mux` once per connection, the
/// way the old link socket did. Every client of the machine's daemon gets that socket: the daemon
/// connection, the CLI's copies, moves, uploads and updates, and the phone. The owner answer is the latest
/// connected line's `vmk`, else the machine record's creator rule.
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
        let socket = try await serve.socketPath()
        // The grant's answer on serve's latest connected line; the record's creator rule until one arrives.
        let granted = CloudCallerOwnership(vmk: await serve.vmk)
        let caller = if let granted { granted } else { await ownership() }
        return CloudLinkSocket(key: key, path: socket, generation: nil, callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
    }

    /// Why the serve child's last dial was refused since this connect, when it was.
    public func refusal(_ key: CloudLinkKey) async -> CloudLinkError? { await serve?.refusal }

    /// Ends the session's `carrier serve` (machine removed, sign-out, quit).
    public func close(_ key: CloudLinkKey) async { await serve?.stop() }
}

/// One Cloud session's `cmux carrier serve --machine <vm_id> --socket <path>` (#37278): started on the first
/// connect and kept for the session; each later connect hands it a fresh access token on stdin
/// (`{"access_token":…}`), since the app has no token refresh signal. Closing stdin stops it (it removes its
/// socket); another starts only once it exited, so two never claim the same socket. After its ready line its
/// stderr names each refused connection's step, which ends the link with that step's wording.
public actor CloudCarrierServe {
    /// `carrier serve` binds at once and dials only per connection, so its ready line comes fast.
    static let readyDeadline: Duration = .seconds(15)
    private let connector: CloudCarrierDial.Connector
    private let socket: String
    private let check: @Sendable (String) throws -> Void
    private var child: ChildProcess?
    private var ready = false
    private var starting: Task<String, any Error>?
    /// The last refused dial since the current connect.
    private(set) var refusal: CloudLinkError?
    /// The `vmk` of the latest connection serve reported connected (`owner` or `team`); nil before one.
    private(set) var vmk: String?

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which ``CloudLinkSocketPolicy`` checks once the child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine)) { try CloudLinkSocketPolicy.check($0) }
    }

    init(connector: CloudCarrierDial.Connector, socket: String, check: @escaping @Sendable (String) throws -> Void) {
        (self.connector, self.socket, self.check) = (connector, socket, check)
    }

    /// The serving socket: a running child gets a fresh access token, else a new child starts (after the
    /// last one exited). Throws ``CloudLinkError`` when it does not get ready.
    public func socketPath() async throws -> String {
        refusal = nil
        if let starting { return try await starting.value }
        if ready, let child, child.isRunning,
           let token = try? await connector.environment()["CMUX_CLOUD_ACCESS_TOKEN"], child.writeInput(line: CloudCarrierDial.tokenLine(token)) {
            return socket
        }
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

    private func noteRefused(_ error: CloudLinkError) { refusal = error }
    private func noteConnected(vmk: String?) { if let vmk { self.vmk = vmk } }

    private func launch() async throws -> String {
        if let previous = child { previous.closeInput(); _ = await previous.waitForExit() }
        ready = false
        let environment = ProcessInfo.processInfo.environment.merging(try await connector.environment()) { $1 }
        let child = ChildProcess(executable: connector.cli, arguments: connector.dial.serveArguments(socket: socket), environment: environment)
        self.child = child
        let (answers, answer) = AsyncStream.makeStream(of: CloudCarrierDial.ServeLine.self, bufferingPolicy: .bufferingNewest(1))
        // One reader for all of stderr: the first answer, then one line per refused connection.
        // task-owner: ends with the child's stderr
        Task { [weak self, lines = child.stderrLines] in
            var answered = false
            for await text in lines {
                guard let line = CloudCarrierDial.serveLine(text) else { continue }
                if !answered { answered = true; answer.yield(line); answer.finish(); continue }
                switch line {
                case .refused(let code, let detail): await self?.noteRefused(CloudCarrierDial.linkError(code: code, detail: detail))
                case .connected(let vmk): await self?.noteConnected(vmk: vmk)
                case .ready: break
                }
            }
            answer.finish()
        }
        do {
            try child.startHoldingInput()
            let first = try await withDeadline(Self.readyDeadline, label: "cmux carrier serve") { () -> CloudCarrierDial.ServeLine? in
                for await line in answers { return line }
                return nil
            }
            switch first {
            case .ready(let served)?:
                guard served == socket else { throw CloudLinkError.invalidAnswer("served another socket") }
                try check(served)
            case .connected?:
                throw CloudLinkError.invalidAnswer("no ready line")
            case .refused(let code, let detail)?:
                throw code == "socket" ? Self.socketTaken : CloudCarrierDial.linkError(code: code, detail: detail)
            case nil:
                // Exit 64 is a usage refusal, a live listener at the path included.
                throw await child.waitForExit() == 64 ? Self.socketTaken : CloudLinkError.helperNotRunning(reason: child.stderrText)
            }
        } catch {
            child.closeInput()
            throw (error as? CloudLinkError) ?? CloudLinkError.helperNotRunning(reason: String(describing: error))
        }
        ready = true
        return socket
    }

    private static let socketTaken = CloudLinkError.failed(code: "socket", message: "another cmux is serving this machine's connection socket")
}

extension CloudCallerOwnership {
    /// A grant's `vmk`: `owner` or `team`; nil for anything else (no answer yet).
    public init?(vmk: String?) {
        switch vmk {
        case "owner": self = .owner
        case "team": self = .team
        default: return nil
        }
    }

    /// The record's rule (cloud-machine-ops.ts `CloudVmKind`): the machine's creator is its `owner`, any
    /// other member of its team is `team`; unknown while either id is missing.
    public init(creator: String?, caller: String?) {
        guard let creator, let caller, !creator.isEmpty, !caller.isEmpty else { self = .unknown; return }
        self = creator == caller ? .owner : .team
    }
}
