import CmuxNextWakeups
public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): one `cmux carrier serve` child for the
/// session (``CloudCarrierServe``), whose private socket dials the machine's `mux` once per connection, the
/// way the old link socket did. Every client of the machine's daemon gets that socket: the daemon
/// connection (its retries and reconnects too, ``redials``), the CLI's copies, moves, uploads and updates,
/// and the phone. The owner answer is the current serve child's latest connected line (its `vmk`; a line
/// without one is never owner), which also updates the live link; the machine record's creator rule
/// applies only before that child answered at all.
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
        // The grant's answer on this child's latest connected line; the record's creator rule only before any.
        let answered = await serve.answer
        let caller = if let answered { answered } else { await ownership() }
        return CloudLinkSocket(key: key, path: socket, generation: nil, callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
    }

    /// The serve child's socket for the Cloud app server: started when it does not run; the refusal this
    /// link reports is left as it is.
    public func carrierSocket(_ key: CloudLinkKey) async throws -> String {
        guard let serve else { throw CloudLinkError.helperNotRunning(reason: "no bundled cmux-tui") }
        return try await serve.socketPath(keepingRefusal: true)
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
/// while it runs (``refreshDelay(_:now:)``), so every new dial carries a live bearer. After its ready line its
/// stderr names each refused connection's step, which ends the link with that step's wording, and each
/// connection's `vmk`.
///
/// The lifecycle is one state machine (``ServeMachine``): this actor only runs its effects and feeds every async
/// result back to it as an event tagged with the epoch or child it belongs to, so a result that comes back after
/// a stop, an account end or a relaunch changes nothing. ``stop()`` and an account end are terminal: a later
/// connect fails as closed and starts nothing (a new session makes a new serve). Closing stdin stops the child
/// (it removes its socket); SIGTERM follows after ``stopGrace``. A relaunch waits for the previous child's exit,
/// and a new instance for the same socket waits for the old instance's child (``CloudCarrierLeases``).
public actor CloudCarrierServe {
    /// `carrier serve` binds at once and dials only per connection, so its ready line comes fast.
    static let readyDeadline: Duration = .seconds(15)
    /// How long a stopped child has, after its stdin closed, before SIGTERM.
    static let stopGrace: Duration = .seconds(5)
    /// The longest a launch waits for another instance's child to give up the socket: its stop grace and SIGTERM.
    static let leaseWait: Duration = stopGrace + .seconds(5)
    private let connector: CloudCarrierDial.Connector
    private let socket: String
    private let check: @Sendable (String) throws -> Void
    private let nextRefresh: @Sendable (String) -> Duration
    private let leases: CloudCarrierLeases
    private let leaseOwner: UInt64
    private var machine: ServeMachine
    /// Events queued while an earlier one's effects run: each event's effects all run before the next reduces.
    private var queue: [ServeMachine.Event] = []
    private var reducing = false
    /// This serve holds a socket claim (``CloudCarrierLeases``) that no child has taken over yet.
    private var claimed = false
    private var children: [ServeMachine.ChildID: ChildProcess] = [:]
    /// Each child's hold in its connector's ``CloudCarrierStreams``: an account end closes it at once.
    private var holds: [ServeMachine.ChildID: Int] = [:]
    private var waiters: [ServeMachine.WaiterID: CheckedContinuation<String, any Error>] = [:]
    private var lastWaiter: ServeMachine.WaiterID = 0
    /// Writes the next token line while the child is ready; cancelled when it leaves ready.
    private let refresher = DemandTimer(owner: "CloudCarrierServe.tokenRefresh")
    private let readyTimer = DemandTimer(owner: "CloudCarrierServe.readyDeadline")
    /// One per stopping (or stale) child; dropped at its exit.
    private var stopTimers: [ServeMachine.ChildID: DemandTimer] = [:]
    private var ownershipObserver: (@Sendable (CloudCallerOwnership) async -> Void)?
    /// The last ownership hand-off: each waits for the one before, so answers arrive in order.
    private var publishing: Task<Void, Never>?

    /// The socket is the machine's `cmux-link-<12 hex>.sock` in this user's private temporary folder
    /// (``CloudPaths``), which ``CloudLinkSocketPolicy`` checks once the child is ready.
    public init(connector: CloudCarrierDial.Connector, paths: CloudPaths) {
        self.init(connector: connector, socket: paths.linkSocket(machineID: connector.dial.machine)) {
            try CloudLinkSocketPolicy.check($0)
        }
    }

    init(connector: CloudCarrierDial.Connector, socket: String, refreshDelay: @escaping @Sendable (String) -> Duration = { CloudCarrierServe.refreshDelay($0) },
         leases: CloudCarrierLeases? = nil, check: @escaping @Sendable (String) throws -> Void) {
        let leases = leases ?? connector.streams?.leases ?? CloudCarrierLeases()
        (self.connector, self.socket, self.check, nextRefresh, self.leases) = (connector, socket, check, refreshDelay, leases)
        leaseOwner = leases.newOwner()
        machine = ServeMachine(socket: socket)
    }

    /// Why the link ended since the current connect: a refused dial's step, the child no longer serving, or
    /// the serve stopped.
    var refusal: CloudLinkError? { machine.refusal }

    /// The ready child's latest connected answer: `owner` or `team` by its `vmk`, `unknown` for a line without
    /// one (never owner). Nil until that child answered once; a new child starts with none.
    var answer: CloudCallerOwnership? { machine.answer }

    /// Whether the token refresh is armed (while a child is ready).
    var refreshing: Bool { machine.isReady }

    var state: ServeMachine.State { machine.state }

    func observeOwnership(_ update: @escaping @Sendable (CloudCallerOwnership) async -> Void) { ownershipObserver = update }

    /// When the next token line goes out after `token`: a minute before its `exp`, at least 15 s on; five
    /// minutes on for a token that names no `exp`.
    static func refreshDelay(_ token: String, now: Date = Date()) -> Duration {
        guard let expiresAt = CloudAccessToken(token: token, team: "").expiresAt else { return .seconds(300) }
        return .seconds(max(expiresAt.timeIntervalSince(now) - 60, 15))
    }

    /// The serving socket: a ready child gets a fresh access token, else a child starts (after the last one
    /// exited), or the launch in flight is joined. Throws ``CloudLinkError`` when it does not get ready, and
    /// `closed` once stopped. `keepingRefusal`: another client asks (the Cloud app server), so the refusal the
    /// session's own connect reads stays.
    public func socketPath(keepingRefusal: Bool = false) async throws -> String {
        lastWaiter &+= 1
        let waiter = lastWaiter
        return try await withCheckedThrowingContinuation { continuation in
            waiters[waiter] = continuation
            send(.connect(waiter, keepRefusal: keepingRefusal))
        }
    }

    /// Ends the serve for good: the child's stdin closes, and a connect or launch still in flight (waiting
    /// for the lease, a token or the previous child's exit) resumes closed and spawns nothing.
    public func stop() { send(.stop) }

    /// Reduces `event`, and every event its effects queue, in order. The fence is read before each one: an
    /// account end that came after the connector was made stops this serve before any later event can hand out
    /// its socket, even when the hold closure's own `accountEnded` hop has not arrived yet.
    func send(_ event: ServeMachine.Event) {
        queue.append(event)
        guard !reducing else { return }
        reducing = true
        defer { reducing = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !machine.isTerminal, connector.isFenced {
                for effect in machine.reduce(.accountEnded) { run(effect) }
            }
            if case .socketClaimed = next { claimed = true }
            for effect in machine.reduce(next) { run(effect) }
            // A claim that no child took over (the launch failed or stopped before its spawn) goes back.
            if claimed, !machine.launching {
                claimed = false
                leases.release(socket, by: leaseOwner)
            }
            if case .childExit(let child, _) = next {
                children[child] = nil
                stopTimers[child] = nil
                if let held = holds.removeValue(forKey: child) { connector.streams?.release(held) }
            }
        }
    }

    private func run(_ effect: ServeMachine.Effect) {
        switch effect {
        case .claimSocket(let epoch): claim(epoch)
        case .readToken(let epoch, let read): readToken(epoch, read: read)
        case .spawn(let child, let environment): spawn(child, environment: environment)
        case .hold(let child): hold(child)
        case .release(let child):
            if let held = holds.removeValue(forKey: child) { connector.streams?.release(held) }
        case .armReadyDeadline(let epoch):
            readyTimer.schedule(after: Self.readyDeadline) { [weak self] in await self?.send(.readyDeadline(epoch)) }
        case .cancelReadyDeadline: readyTimer.cancel()
        case .armRefresh(let epoch, let token):
            refresher.schedule(after: nextRefresh(token ?? "")) { [weak self] in await self?.send(.refreshDue(epoch)) }
        case .cancelRefresh: refresher.cancel()
        case .writeToken(let child, let token):
            let ok = children[child]?.writeInput(line: CloudCarrierDial.tokenLine(token)) ?? false
            queue.append(.tokenWritten(child: child, token: token, ok: ok))
        case .closeStdin(let child): children[child]?.closeInput()
        case .armStopDeadline(let child):
            let timer = DemandTimer(owner: "CloudCarrierServe.stopDeadline")
            stopTimers[child] = timer
            timer.schedule(after: Self.stopGrace) { [weak self] in await self?.send(.stopDeadline(child: child)) }
        case .terminate(let child): children[child]?.terminate()
        case .terminateAfterGrace(let child):
            guard let process = children[child] else { return }
            let timer = DemandTimer(owner: "CloudCarrierServe.stopDeadline")
            stopTimers[child] = timer
            timer.schedule(after: Self.stopGrace) { process.terminate() }
        case .resume(let ids, let result):
            for id in ids { waiters.removeValue(forKey: id)?.resume(with: result.mapError { $0 as any Error }) }
        case .publish(let caller):
            let (previous, observer) = (publishing, ownershipObserver)
            // task-owner: one observer call, after the one before it
            publishing = Task {
                await previous?.value
                await observer?(caller)
            }
        }
    }

    /// The socket lease: at once when no other instance holds the path, else once it gave it up (bounded by
    /// ``leaseWait``, then taken anyway). The claim is atomic, so two instances waiting on one exit never both
    /// launch.
    private func claim(_ epoch: ServeMachine.Epoch) {
        if leases.claim(socket, by: leaseOwner) {
            queue.append(.socketClaimed(epoch))
            return
        }
        let (leases, socket, owner) = (leases, socket, leaseOwner)
        let deadline = ContinuousClock.now + Self.leaseWait
        // task-owner: ends once this epoch holds the socket, at leaseWait, or when the serve left this claim
        Task { [weak self] in
            while let serve = self, await serve.isClaiming(epoch) {
                if leases.claim(socket, by: owner, force: ContinuousClock.now >= deadline) {
                    await serve.send(.socketClaimed(epoch))
                    return
                }
                await leases.released(socket, besides: owner, until: deadline)
            }
        }
    }

    private func isClaiming(_ epoch: ServeMachine.Epoch) -> Bool { machine.state == .claiming(epoch) }

    private func readToken(_ epoch: ServeMachine.Epoch, read: ServeMachine.ReadID) {
        let connector = connector
        // task-owner: one token read; its answer is dropped when the epoch moved on
        Task { [weak self] in
            let result: ServeMachine.TokenRead
            do {
                let environment = try await connector.environment()
                // A switch during the read hands the token to no one.
                result = connector.isFenced ? .fenced : .ok(environment)
            } catch let error as CloudLinkError where error == CloudCarrierDial.Connector.fenced {
                result = .fenced
            } catch let error as CloudLinkError {
                result = .failed(error)
            } catch {
                result = .failed(.helperNotRunning(reason: "cmux carrier serve has no access token: \(error)"))
            }
            await self?.send(.tokenRead(epoch, read: read, result))
        }
    }

    private func spawn(_ child: ServeMachine.ChildID, environment fresh: [String: String]) {
        let environment = ProcessInfo.processInfo.environment.merging(fresh) { $1 }
        let process = ChildProcess(executable: connector.cli, arguments: connector.dial.serveArguments(socket: socket), environment: environment)
        do {
            try process.startHoldingInput()
        } catch {
            // It never ran (ChildProcess recorded its exit): nothing to wait on.
            queue.append(.spawned(child: child, failure: .disconnected(reason: "cmux carrier serve did not start: \(error.localizedDescription)")))
            return
        }
        children[child] = process
        leases.hold(socket, by: leaseOwner, child: process)
        claimed = false
        let check = check
        // One reader per child, in order: every stderr line, then the end of stderr, then the exit.
        // task-owner: ends with the child's stderr and its exit
        Task { [weak self, lines = process.stderrLines] in
            for await text in lines {
                guard let line = CloudCarrierDial.serveLine(text) else { continue }
                await self?.send(Self.event(line, child: child, check: check))
            }
            await self?.send(.stderrEnded(child: child, stderr: process.stderrText))
            let code = await process.waitForExit()
            await self?.send(.childExit(child: child, code: code))
        }
        queue.append(.spawned(child: child, failure: nil))
    }

    private static func event(_ line: CloudCarrierDial.ServeLine, child: ServeMachine.ChildID, check: (String) throws -> Void) -> ServeMachine.Event {
        switch line {
        case .ready(let served):
            var policy: CloudLinkError?
            do { try check(served) } catch { policy = (error as? CloudLinkError) ?? .helperNotRunning(reason: String(describing: error)) }
            return .readyLine(child: child, socket: served, policy: policy)
        case .connected(let vmk): return .okLine(child: child, vmk: vmk)
        case .refused(let code, let detail): return .refusalLine(child: child, code: code, detail: detail)
        }
    }

    /// It carries this account's token: an account end (``CloudCarrierStreams/endAll()``) closes it at once and
    /// tells this serve, which then stops for good; one that came first closed it already.
    private func hold(_ child: ServeMachine.ChildID) {
        guard let streams = connector.streams, let process = children[child] else { return }
        let id = streams.hold(generation: connector.generation) { [weak self] in
            process.closeInput()
            // task-owner: one hop that tells the serve its account ended
            Task { await self?.send(.accountEnded) }
        }
        if let id { holds[child] = id }
        queue.append(.heldResult(child: child, held: id != nil))
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
