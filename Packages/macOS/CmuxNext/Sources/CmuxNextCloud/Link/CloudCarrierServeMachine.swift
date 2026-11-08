/// The lifecycle of one session's `cmux carrier serve` as one pure reducer: ``reduce(_:)`` takes an event, commits
/// the next state and returns the effects to run, in order, after that commit. ``CloudCarrierServe`` runs the
/// effects (it spawns, reads, writes and arms timers) and feeds each async result back as an event. No effect
/// writes state, and no transition awaits.
///
/// The rules, stated once:
/// - Every result event carries the epoch or the child it was started for; one that no longer matches the state is
///   dropped. The one exception is a stale successful spawn: its child is closed and terminated after a grace.
/// - ``Event/stop`` and ``Event/accountEnded`` are terminal: every parked connect resumes `closed` in the same
///   turn, the child's stdin closes, and a later connect fails `closed` with no effect. A new serve is a new
///   instance (``CloudService`` makes one per session).
/// - A token is written, and a socket handed out, only as an effect of a transition out of `ready`.
/// - Connects while a launch is in flight join it: there is never a second child.
/// - ``ChildID`` is issued (the epoch the child was spawned in), never read from `===`, an inode or a path.
struct ServeMachine: Sendable {
    typealias Epoch = UInt64
    /// A child's issued id: the epoch it was spawned in (one child per epoch).
    typealias ChildID = UInt64
    typealias WaiterID = UInt64
    typealias ReadID = UInt64

    enum StopReason: Equatable, Sendable {
        /// ``CloudCarrierResolver/close(_:)``: the machine removed, sign-out, quit, Cloud turned off by policy.
        case closed
        /// The connector's ``CloudCarrierStreams`` ended (an account or team switch, sign-out, policy).
        case accountEnded
    }

    /// What a ready child has: the token it got last, its latest connected answer, the last refused dial since
    /// the current connect, and the token read in flight (a connect's or the refresh's).
    struct Ready: Equatable, Sendable {
        var sentToken: String?
        var answer: CloudCallerOwnership?
        var refused: CloudLinkError?
        var tokenRead: ReadID?
    }

    enum State: Equatable, Sendable {
        /// No launch in flight. `lastEnd`: why the last child or launch ended (``refusal``). `alive`: a child whose
        /// stdin is closed and whose exit has not come yet; the next launch drains it first.
        case idle(lastEnd: CloudLinkError?, alive: ChildID?)
        /// Waiting for the process-wide socket lease (``CloudCarrierLeases``).
        case claiming(Epoch)
        /// Waiting for this instance's previous child to exit before the relaunch.
        case draining(Epoch, child: ChildID)
        /// The connector's environment (the access token) is being read.
        case awaitingToken(Epoch, read: ReadID)
        /// Spawned and held in the fence; waiting for the ready line.
        case spawning(Epoch, child: ChildID, sentToken: String?)
        /// Serving the socket; the token refresh is armed.
        case ready(Epoch, child: ChildID, Ready)
        /// Terminal intent: stdin closed, waiting for the exit (then SIGTERM at the deadline).
        case stopping(child: ChildID, StopReason)
        case stopped(StopReason)
    }

    enum TokenRead: Equatable, Sendable {
        case ok([String: String])
        case failed(CloudLinkError)
        /// The connector is bound to an account that is no longer signed in.
        case fenced
    }

    enum Event: Equatable, Sendable {
        case connect(WaiterID, keepRefusal: Bool)
        case stop
        case accountEnded
        case socketClaimed(Epoch)
        case tokenRead(Epoch, read: ReadID, TokenRead)
        case spawned(child: ChildID, failure: CloudLinkError?)  // failure nil: the child runs
        case heldResult(child: ChildID, held: Bool)  // held false: the fence ended first (and closed the child)
        case readyLine(child: ChildID, socket: String, policy: CloudLinkError?)  // policy: the socket check's refusal
        case okLine(child: ChildID, vmk: String?)
        case refusalLine(child: ChildID, code: String, detail: String?)
        case stderrEnded(child: ChildID, stderr: String)  // its tail; the exit follows
        case readyDeadline(Epoch)
        case childExit(child: ChildID, code: Int32)
        case refreshDue(Epoch)
        case tokenWritten(child: ChildID, token: String, ok: Bool)
        case stopDeadline(child: ChildID)
    }

    enum Effect: Equatable, Sendable {
        case claimSocket(Epoch)
        case readToken(Epoch, read: ReadID)
        case spawn(child: ChildID, environment: [String: String])
        case hold(child: ChildID)
        case release(child: ChildID)
        case armReadyDeadline(Epoch)
        case cancelReadyDeadline
        case armRefresh(Epoch, token: String?)
        case cancelRefresh
        case writeToken(child: ChildID, token: String)
        case closeStdin(child: ChildID)
        case armStopDeadline(child: ChildID)
        case terminate(child: ChildID)
        case terminateAfterGrace(child: ChildID)
        case resume([WaiterID], Result<String, CloudLinkError>)
        case publish(CloudCallerOwnership)
    }

    static let closed = CloudLinkError.disconnected(reason: "closed")
    static let exited = CloudLinkError.helperNotRunning(reason: "cmux carrier serve exited")
    static let noReadyLine = CloudLinkError.helperNotRunning(reason: "cmux carrier serve missed its deadline")
    static let tokenKey = "CMUX_CLOUD_ACCESS_TOKEN"

    /// The socket this serve claims; a ready line naming another one is refused.
    let socket: String
    private(set) var state = State.idle(lastEnd: nil, alive: nil)
    /// Bumped by every launch and by every exit from a child-bound phase.
    private(set) var epoch: Epoch = 0
    /// Connects parked until the launch, or the ready child's token read, answers.
    private(set) var waiters: [WaiterID] = []
    private var lastRead: ReadID = 0

    init(socket: String) { self.socket = socket }

    /// Why the link ended since the current connect: a refused dial's step, why the last child or launch ended,
    /// or that the serve was stopped. Nil while a launch is in flight.
    var refusal: CloudLinkError? {
        switch state {
        case .ready(_, _, let ready): ready.refused
        case .idle(let lastEnd, _): lastEnd ?? Self.exited
        case .claiming, .draining, .awaitingToken, .spawning: nil
        case .stopping, .stopped: Self.closed
        }
    }

    /// The ready child's latest connected answer; nil until it answered once, and in every other state.
    var answer: CloudCallerOwnership? {
        if case .ready(_, _, let ready) = state { return ready.answer }
        return nil
    }

    var isReady: Bool { if case .ready = state { true } else { false } }

    /// A launch between its socket claim and its child: the claim is still the launch's own.
    var launching: Bool { if case .awaitingToken = state { true } else if case .spawning = state { true } else { false } }

    var isTerminal: Bool { if case .stopping = state { true } else if case .stopped = state { true } else { false } }

    /// The child this state owns, if any.
    var child: ChildID? {
        switch state {
        case .idle(_, let alive): alive
        case .draining(_, let child), .spawning(_, let child, _), .ready(_, let child, _), .stopping(let child, _): child
        case .claiming, .awaitingToken, .stopped: nil
        }
    }

    mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case .connect(let waiter, let keepRefusal): return connect(waiter, keepRefusal: keepRefusal)
        case .stop: return stop(.closed)
        case .accountEnded: return stop(.accountEnded)
        case .socketClaimed(let at):
            guard case .claiming(at) = state else { return [] }
            let read = nextRead()
            state = .awaitingToken(at, read: read)
            return [.readToken(at, read: read)]
        case .tokenRead(let at, let read, let result): return tokenRead(at, read: read, result)
        case .spawned(let child, let failure): return spawned(child, failure: failure)
        case .heldResult(let child, let held):
            guard case .spawning(_, child, _) = state, !held else { return [] }
            return stop(.accountEnded)
        case .readyLine(let child, let served, let policy):
            guard case .spawning(let at, child, let sentToken) = state else { return [] }
            if served != socket { return fail(child, .invalidAnswer("served another socket")) }
            if let policy { return fail(child, policy) }
            state = .ready(at, child: child, Ready(sentToken: sentToken))
            return [.cancelReadyDeadline, .armRefresh(at, token: sentToken)] + resumeAll(.success(socket))
        case .okLine(let child, let vmk): return okLine(child, vmk: vmk)
        case .refusalLine(let child, let code, let detail): return refusalLine(child, code: code, detail: detail)
        case .stderrEnded(let child, let stderr):
            guard case .spawning(_, child, _) = state else { return [] }  // in ready, the exit follows
            return fail(child, .helperNotRunning(reason: stderr))
        case .readyDeadline(let at):
            guard case .spawning(at, let child, _) = state else { return [] }
            return fail(child, Self.noReadyLine)
        case .childExit(let child, _): return childExit(child)
        case .refreshDue(let at):
            guard case .ready(at, let child, var ready) = state, ready.tokenRead == nil else { return [] }
            let read = nextRead()
            ready.tokenRead = read
            state = .ready(at, child: child, ready)
            return [.readToken(at, read: read)]
        case .tokenWritten(let child, let token, let ok): return tokenWritten(child, token: token, ok: ok)
        case .stopDeadline(let child):
            guard case .stopping(child, _) = state else { return [] }
            return [.terminate(child: child)]
        }
    }

    private mutating func connect(_ waiter: WaiterID, keepRefusal: Bool) -> [Effect] {
        switch state {
        case .stopping, .stopped:
            return [.resume([waiter], .failure(Self.closed))]
        case .idle(_, let alive):
            waiters.append(waiter)
            return launch(draining: alive)
        case .claiming, .draining, .awaitingToken, .spawning:
            // Join the launch in flight: never a second child.
            waiters.append(waiter)
            return []
        case .ready(let at, let child, var ready):
            if !keepRefusal { ready.refused = nil }
            waiters.append(waiter)
            var effects: [Effect] = []
            if ready.tokenRead == nil {
                let read = nextRead()
                ready.tokenRead = read
                effects.append(.readToken(at, read: read))
            }
            state = .ready(at, child: child, ready)
            return effects
        }
    }

    /// A new epoch's launch: after this instance's previous child exited, else after the socket lease.
    private mutating func launch(draining alive: ChildID?) -> [Effect] {
        epoch &+= 1
        if let alive {
            state = .draining(epoch, child: alive)
            return []
        }
        state = .claiming(epoch)
        return [.claimSocket(epoch)]
    }

    private mutating func stop(_ reason: StopReason) -> [Effect] {
        if isTerminal { return [] }
        var effects: [Effect] = []
        switch state {
        case .spawning: effects.append(.cancelReadyDeadline)
        case .ready: effects.append(.cancelRefresh)
        default: break
        }
        let child = self.child
        epoch &+= 1
        if let child {
            effects += [.closeStdin(child: child), .release(child: child)]
            state = .stopping(child: child, reason)
        } else {
            state = .stopped(reason)
        }
        effects += resumeAll(.failure(Self.closed))
        if let child { effects.append(.armStopDeadline(child: child)) }
        return effects
    }

    private mutating func tokenRead(_ at: Epoch, read: ReadID, _ result: TokenRead) -> [Effect] {
        switch state {
        case .awaitingToken(at, read):
            switch result {
            case .ok(let environment):
                state = .spawning(at, child: at, sentToken: environment[Self.tokenKey])
                return [.spawn(child: at, environment: environment)]
            case .failed(let error):
                state = .idle(lastEnd: error, alive: nil)
                return resumeAll(.failure(error))
            case .fenced:
                return stop(.accountEnded)
            }
        case .ready(at, let child, var ready) where ready.tokenRead == read:
            ready.tokenRead = nil
            state = .ready(at, child: child, ready)
            switch result {
            case .ok(let environment):
                if let token = environment[Self.tokenKey], token != ready.sentToken {
                    // The connects resume once the write answered (``Event/tokenWritten``).
                    return [.writeToken(child: child, token: token)]
                }
                return answered(at, ready)
            case .failed:
                // A failed lookup keeps the healthy child on its last token.
                return answered(at, ready)
            case .fenced:
                return stop(.accountEnded)
            }
        default:
            return []
        }
    }

    private mutating func tokenWritten(_ child: ChildID, token: String, ok: Bool) -> [Effect] {
        guard case .ready(let at, child, var ready) = state else { return [] }
        guard ok else { return gone(child, alive: true) }
        ready.sentToken = token
        state = .ready(at, child: child, ready)
        return answered(at, ready)
    }

    /// A ready child's token read finished: the parked connects get the socket and the refresh re-arms.
    private mutating func answered(_ at: Epoch, _ ready: Ready) -> [Effect] {
        resumeAll(.success(socket)) + [.armRefresh(at, token: ready.sentToken)]
    }

    private mutating func spawned(_ child: ChildID, failure: CloudLinkError?) -> [Effect] {
        guard case .spawning(_, child, _) = state else {
            // A stale spawn never orphans its child.
            return failure == nil ? [.closeStdin(child: child), .terminateAfterGrace(child: child)] : []
        }
        if let failure {
            // It never ran: no child is kept for the next launch to wait on.
            state = .idle(lastEnd: failure, alive: nil)
            return resumeAll(.failure(failure))
        }
        return [.hold(child: child), .armReadyDeadline(child)]
    }

    private mutating func okLine(_ child: ChildID, vmk: String?) -> [Effect] {
        switch state {
        case .spawning(_, child, _):
            return fail(child, .invalidAnswer("no ready line"))
        case .ready(let at, child, var ready):
            let caller = CloudCallerOwnership(vmk: vmk) ?? .unknown
            ready.answer = caller
            state = .ready(at, child: child, ready)
            return [.publish(caller)]
        default:
            return []
        }
    }

    private mutating func refusalLine(_ child: ChildID, code: String, detail: String?) -> [Effect] {
        switch state {
        case .spawning(_, child, _):
            return fail(child, CloudCarrierDial.serveStartError(code: code, detail: detail, socket: socket))
        case .ready(let at, child, var ready):
            guard let refusal = CloudCarrierDial.serveRefusal(code: code, detail: detail) else { return [] }
            ready.refused = refusal
            state = .ready(at, child: child, ready)
            return []
        default:
            return []
        }
    }

    private mutating func childExit(_ child: ChildID) -> [Effect] {
        switch state {
        case .spawning(_, child, _):
            // Stderr ends before the exit is read, so this is only a reader that never saw EOF.
            let effects = fail(child, Self.exited)
            state = .idle(lastEnd: Self.exited, alive: nil)
            return effects
        case .ready(_, child, _):
            return gone(child, alive: false)
        case .draining(let at, child):
            state = .claiming(at)
            return [.claimSocket(at)]
        case .idle(let lastEnd, child):
            state = .idle(lastEnd: lastEnd, alive: nil)
            return []
        case .stopping(child, let reason):
            state = .stopped(reason)
            return []
        default:
            return []
        }
    }

    /// A launch that did not get ready: the child's stdin closes and the parked connects get `error`.
    private mutating func fail(_ child: ChildID, _ error: CloudLinkError) -> [Effect] {
        epoch &+= 1
        state = .idle(lastEnd: error, alive: child)
        return [.cancelReadyDeadline, .closeStdin(child: child), .release(child: child)] + resumeAll(.failure(error))
    }

    /// The ready child exited (`alive` false) or stopped taking stdin (`alive` true). The refusal is its last
    /// refused dial, else that it exited; parked connects relaunch.
    private mutating func gone(_ child: ChildID, alive: Bool) -> [Effect] {
        guard case .ready(_, child, let ready) = state else { return [] }
        epoch &+= 1
        let exiting = alive ? child : nil
        state = .idle(lastEnd: ready.refused ?? Self.exited, alive: exiting)
        var effects: [Effect] = [.cancelRefresh]
        if exiting != nil { effects.append(.closeStdin(child: child)) }
        effects.append(.release(child: child))
        if !waiters.isEmpty { effects += launch(draining: exiting) }
        return effects
    }

    private mutating func resumeAll(_ result: Result<String, CloudLinkError>) -> [Effect] {
        guard !waiters.isEmpty else { return [] }
        defer { waiters = [] }
        return [.resume(waiters, result)]
    }

    private mutating func nextRead() -> ReadID {
        lastRead &+= 1
        return lastRead
    }
}
