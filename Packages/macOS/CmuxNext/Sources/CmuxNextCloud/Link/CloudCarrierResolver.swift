import CmuxNextWakeups
public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): one `cmux carrier serve` child for the
/// session (``CloudCarrierServe``), whose private socket dials the machine's `mux` once per connection, the
/// way the old link socket did. Every client of the machine's daemon gets that socket: the daemon
/// connection (its retries and reconnects too, ``redials``), the CLI's copies, moves, uploads and updates,
/// and the phone. The owner answer is the latest connected line's `vmk`, which also updates the live link,
/// else the machine record's creator rule.
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

    /// Why the serve child's last dial was refused since this connect, or that the child is gone.
    public func refusal(_ key: CloudLinkKey) async -> CloudLinkError? { await serve?.refusal }

    public var redials: Bool { true }

    public func observeOwnership(_ key: CloudLinkKey, _ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) async {
        await serve?.observeOwnership(update)
    }

    /// Ends the session's `carrier serve` (machine removed, sign-out, quit).
    public func close(_ key: CloudLinkKey) async { await serve?.stop() }
}

/// One Cloud session's `cmux carrier serve --machine <vm_id> --socket <path>` (#37278): started on the first
/// connect and kept for the session. It gets a fresh access token on stdin (`{"access_token":…}`) at each
/// later connect and, since the app's auth has no refresh signal, a minute before the last token's `exp`
/// while it runs (``refreshDelay(_:now:)``), so every new dial carries a live bearer. Closing stdin stops it
/// (it removes its socket); another starts only once it exited, so two never claim the same socket. After
/// its ready line its stderr names each refused connection's step, which ends the link with that step's
/// wording, and each connection's `vmk`.
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
    private var refused: CloudLinkError?
    /// The `vmk` of the latest connection serve reported connected (`owner` or `team`); nil before one.
    private(set) var vmk: String?
    private var ownershipObserver: (@Sendable (CloudCallerOwnership) async -> Void)?
    /// The last token the child got (environment or stdin).
    private var sentToken: String?
    /// Writes the next token line while the child runs; cancelled when it exits.
    private let refresher = DemandTimer(owner: "CloudCarrierServe.tokenRefresh")
    /// Whether the token refresh runs (it ends with the child).
    private(set) var refreshing = false
    private let nextRefresh: @Sendable (String) -> Duration

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which ``CloudLinkSocketPolicy`` checks once the child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine)) { try CloudLinkSocketPolicy.check($0) }
    }

    init(connector: CloudCarrierDial.Connector, socket: String, refreshDelay: @escaping @Sendable (String) -> Duration = { CloudCarrierServe.refreshDelay($0) },
         check: @escaping @Sendable (String) throws -> Void) {
        (self.connector, self.socket, self.check, nextRefresh) = (connector, socket, check, refreshDelay)
    }

    /// Why the link ended since the current connect: a refused dial's step, or the child no longer serving.
    var refusal: CloudLinkError? {
        if let refused { return refused }
        guard starting == nil, !(ready && child?.isRunning == true) else { return nil }
        return .helperNotRunning(reason: "cmux carrier serve exited")
    }

    func observeOwnership(_ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) { ownershipObserver = update }

    /// When the next token line goes out after `token`: a minute before its `exp`, at least 15 s on; five
    /// minutes on for a token that names no `exp`.
    static func refreshDelay(_ token: String, now: Date = Date()) -> Duration {
        guard let expiresAt = CloudAccessToken(token: token, team: "").expiresAt else { return .seconds(300) }
        return .seconds(max(expiresAt.timeIntervalSince(now) - 60, 15))
    }

    /// The serving socket: a running child gets a fresh access token, else a new child starts (after the
    /// last one exited). Throws ``CloudLinkError`` when it does not get ready.
    public func socketPath() async throws -> String {
        refused = nil
        if let starting { return try await starting.value }
        if ready, let child, child.isRunning,
           let token = try? await connector.environment()["CMUX_CLOUD_ACCESS_TOKEN"], child.writeInput(line: CloudCarrierDial.tokenLine(token)) {
            sentToken = token
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

    private func noteRefused(_ error: CloudLinkError) { refused = error }

    private func noteConnected(vmk: String?) async {
        guard let vmk, let caller = CloudCallerOwnership(vmk: vmk) else { return }
        self.vmk = vmk
        await ownershipObserver?(caller)
    }

    private func childExited(_ exited: ChildProcess) {
        guard exited === child else { return }
        refresher.cancel()
        refreshing = false
    }

    /// The next token line, a minute before the last token expires; nothing once the child is gone.
    private func scheduleRefresh(_ serving: ChildProcess) {
        guard serving === child, serving.isRunning else { refreshing = false; return }
        refreshing = true
        refresher.schedule(after: nextRefresh(sentToken ?? "")) { [weak self] in await self?.refreshToken(serving) }
    }

    /// Hands the running child a fresh token (when the auth layer has a new one), then schedules the next.
    private func refreshToken(_ serving: ChildProcess) async {
        guard serving === child, serving.isRunning else { refreshing = false; return }
        if let token = try? await connector.environment()["CMUX_CLOUD_ACCESS_TOKEN"], token != sentToken, serving === child,
           serving.writeInput(line: CloudCarrierDial.tokenLine(token)) {
            sentToken = token
        }
        scheduleRefresh(serving)
    }

    private func launch() async throws -> String {
        if let previous = child { previous.closeInput(); _ = await previous.waitForExit() }
        ready = false
        let environment = ProcessInfo.processInfo.environment.merging(try await connector.environment()) { $1 }
        let child = ChildProcess(executable: connector.cli, arguments: connector.dial.serveArguments(socket: socket), environment: environment)
        self.child = child
        sentToken = environment["CMUX_CLOUD_ACCESS_TOKEN"]
        let (answers, answer) = AsyncStream.makeStream(of: CloudCarrierDial.ServeLine.self, bufferingPolicy: .bufferingNewest(1))
        // One reader for all of stderr: the first answer, then one line per refused connection.
        // task-owner: ends with the child's stderr
        Task { [weak self, lines = child.stderrLines] in
            var answered = false
            for await text in lines {
                guard let line = CloudCarrierDial.serveLine(text) else { continue }
                if !answered { answered = true; answer.yield(line); answer.finish(); continue }
                switch line {
                case .refused(let code, let detail):
                    if let refusal = CloudCarrierDial.serveRefusal(code: code, detail: detail) { await self?.noteRefused(refusal) }
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
                throw CloudCarrierDial.serveStartError(code: code, detail: detail, socket: socket)
            case nil:
                // Serve writes a line before every exit; none means it never ran.
                throw CloudLinkError.helperNotRunning(reason: child.stderrText)
            }
        } catch {
            child.closeInput()
            throw (error as? CloudLinkError) ?? CloudLinkError.helperNotRunning(reason: String(describing: error))
        }
        ready = true
        scheduleRefresh(child)
        // task-owner: ends when the child exits
        Task { [weak self] in _ = await child.waitForExit(); await self?.childExited(child) }
        return socket
    }
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
