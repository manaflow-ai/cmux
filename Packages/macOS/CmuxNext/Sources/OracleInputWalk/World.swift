import CmuxFuzzSupport
import CmuxNextDaemon
import CmuxNextInputModel
import Foundation

typealias Machine = TerminalAttachMachine<Int>

/// How one walk is set up, from its seed alone.
struct WalkConfig: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Terminal views started before the first step.
    var terminals: Int
    /// Views start visible and not restoring, and streams end only for the reasons the journal
    /// names (`ended:overflow`, `ended:other`): the walk's journal then replays exactly.
    var exact: Bool

    init(seed: UInt64) {
        terminals = 1 + Int(seed % 3)
        exact = (seed / 3) % 2 == 0
    }

    var description: String { "terminals: \(terminals), exact: \(exact)" }
}

/// One step of an attach walk (plans/cmux-next/input-spec.md section 6): an event of a terminal
/// view, or of the driver and the daemon behind it. Parameters are indices resolved against the
/// world when the step runs (modulo the live count), so any subsequence of a walk is still a walk:
/// that is what makes shrinking work.
enum WalkAction: Hashable, Sendable {
    // The view.
    /// A terminal view is created and starts attaching.
    case start(visible: Bool, restoring: Bool)
    case close(terminal: Int)
    /// `large`: 1 MiB, so a few fill the machine's 4 MiB queue cap while it attaches.
    case input(terminal: Int, large: Bool)
    case resize(terminal: Int, size: Int)
    case visibility(terminal: Int, visible: Bool)
    case focused(terminal: Int)
    case takeOver(terminal: Int, setLatest: Bool)
    /// The terminal or the daemon connection is back.
    case reconnect(terminal: Int)
    case processExited(terminal: Int)
    case processRevived(terminal: Int)
    // The driver and the daemon.
    /// An open the machine asked for completes with a new link, or fails.
    case completeOpen(terminal: Int, open: Int, fails: Bool)
    /// An open for the attempt before the pending one completes (late, or a second time).
    case lateOpen(terminal: Int)
    case replay(terminal: Int, link: Int)
    /// A stream announces the PTY grid (another client sized the terminal).
    case grid(terminal: Int, link: Int, size: Int)
    /// 0 overflow, 1 surface gone, 2 detached by the client, 3 connection lost (not in exact walks).
    case ended(terminal: Int, link: Int, reason: Int)

    /// A random step. The weights favor the driver's races: opens, replays and stream ends
    /// delivered in any order, late or never.
    static func random(_ rng: inout FuzzRNG) -> WalkAction {
        let terminal = rng.below(8)
        let index = rng.below(8)
        let flag = rng.bool()
        switch rng.below(30) {
        case 0: return .start(visible: flag, restoring: rng.oneIn(4))
        case 1: return .close(terminal: terminal)
        case 2...5: return .input(terminal: terminal, large: rng.oneIn(64))
        case 6, 7: return .resize(terminal: terminal, size: index)
        case 8, 9: return .visibility(terminal: terminal, visible: flag)
        case 10: return .focused(terminal: terminal)
        case 11: return .takeOver(terminal: terminal, setLatest: flag)
        case 12: return .reconnect(terminal: terminal)
        case 13: return .processExited(terminal: terminal)
        case 14: return .processRevived(terminal: terminal)
        case 15...19: return .completeOpen(terminal: terminal, open: index, fails: rng.oneIn(4))
        case 20: return .lateOpen(terminal: terminal)
        case 21...24: return .replay(terminal: terminal, link: index)
        case 25, 26: return .grid(terminal: terminal, link: index, size: rng.below(8))
        default: return .ended(terminal: terminal, link: index, reason: rng.below(4))
        }
    }
}

/// The attach part of the composed input system (plans/cmux-next/input-spec.md section 6): the
/// real `TerminalAttachMachine` per terminal view, checked by `AttachOracle` (A1-A4) at every
/// reduction, around a simulated `TerminalAttachDriver` and daemon that answer the machine's opens,
/// deliver replays, grid announcements and stream ends in any order, late or not at all, and apply
/// its detaches. Every reduction is journaled as `InputJournal.attachObserver` records it, so a
/// walk is a journal that `debug.replay` and `oracle-replay` read.
struct AttachWorld {
    struct Terminal {
        let surface: String
        var machine: Machine
        var oracle = AttachOracle<Int>()
        /// Attempts of the machine's `open` effects the driver has not answered, oldest first.
        var requested: [Int] = []
        /// Links the driver returned, oldest first.
        var links: [Int] = []
        var detached: Set<Int> = []
        var replayed: Set<Int> = []
        var ended: Set<Int> = []
        var chunks: UInt32 = 0

        /// Links whose stream still runs: returned, not detached, not ended.
        var streaming: [Int] { links.filter { !detached.contains($0) && !ended.contains($0) } }
    }

    /// A bug planted in the simulated driver, so a run can show the oracle and the shrinker
    /// catch one (`--plant-fault`).
    enum Fault: String, Hashable, Sendable {
        /// The driver loses the first detach the machine asks for.
        case lostDetach = "lost-detach"
    }

    static let maxTerminals = 6
    /// The grids views settle on and streams announce: few, so a claim of the size already
    /// announced (no echo due) is common.
    static let sizes = [
        CellSize(cols: 80, rows: 24), CellSize(cols: 100, rows: 30), CellSize(cols: 80, rows: 25), CellSize(cols: 7, rows: 5),
        CellSize(cols: 120, rows: 40), CellSize(cols: 80, rows: 24), CellSize(cols: 200, rows: 60), CellSize(cols: 100, rows: 30),
    ]

    let config: WalkConfig
    let fault: Fault?
    private(set) var terminals: [Terminal] = []
    private(set) var violations: [InputViolation] = []
    private(set) var journal: [InputJournalEntry] = []
    private var nextLink = 1
    private var faultHit = false

    init(config: WalkConfig, fault: Fault? = nil) {
        self.config = config
        self.fault = fault
        for _ in 0..<config.terminals { start(visible: true, restoring: false) }
    }

    mutating func perform(_ action: WalkAction) {
        switch action {
        case .start(let visible, let restoring):
            start(visible: visible || config.exact, restoring: restoring && !config.exact)
        case .close(let n): view(n) { _ in .close }
        case .input(let n, let large):
            view(n) { terminal in
                terminal.chunks &+= 1
                return .input(Self.chunk(terminal.chunks, large: large))
            }
        case .resize(let n, let size): view(n) { _ in .resize(Self.sizes[size % Self.sizes.count]) }
        case .visibility(let n, let visible): view(n) { _ in .visibility(visible) }
        case .focused(let n): view(n) { _ in .focused }
        case .takeOver(let n, let setLatest): view(n) { _ in .takeOver(setLatest: setLatest) }
        case .reconnect(let n): view(n) { _ in .reconnect }
        case .processExited(let n): view(n) { _ in .processExited }
        case .processRevived(let n): view(n) { _ in .processRevived }
        case .completeOpen(let n, let open, let fails):
            let link = takeLink()
            driver(n) { terminal in
                guard !terminal.requested.isEmpty else { return nil }
                let attempt = terminal.requested.remove(at: open % terminal.requested.count)
                return fails ? .openFailed(attempt: attempt) : .opened(link, attempt: attempt)
            }
        case .lateOpen(let n):
            let link = takeLink()
            driver(n) { terminal in
                guard let pending = Self.pending(terminal.machine), pending.attempt > 1 else { return nil }
                let attempt = pending.attempt - 1
                terminal.requested.removeAll { $0 == attempt }
                return .opened(link, attempt: attempt)
            }
        case .replay(let n, let index):
            driver(n) { terminal in
                let waiting = terminal.streaming.filter { !terminal.replayed.contains($0) }
                return waiting.isEmpty ? nil : .replayDelivered(waiting[index % waiting.count])
            }
        case .grid(let n, let index, let size):
            driver(n) { terminal in
                let streams = terminal.streaming
                return streams.isEmpty ? nil : .gridAnnounced(streams[index % streams.count], Self.sizes[size % Self.sizes.count])
            }
        case .ended(let n, let index, let choice):
            let reason = Self.closeReason(choice, exact: config.exact)
            driver(n) { terminal in
                let streams = terminal.streaming
                return streams.isEmpty ? nil : .ended(streams[index % streams.count], reason)
            }
        }
    }

    /// Ends the walk: every view closes, then every open still in flight completes, so each
    /// terminal shows whether every link it was given was detached exactly once (A3).
    mutating func settle() {
        for index in terminals.indices where !terminals[index].machine.isClosed {
            reduce(index) { _ in .close }
        }
        for index in terminals.indices {
            // A closed machine asks for no open; the bound only stops a machine that keeps asking.
            for _ in 0..<64 where !terminals[index].requested.isEmpty {
                let link = takeLink()
                reduce(index) { terminal in .opened(link, attempt: terminal.requested.removeFirst()) }
            }
        }
        for terminal in terminals {
            for link in terminal.links where !terminal.detached.contains(link) {
                violations.append(InputViolation(invariant: .detachOnce, window: nil,
                                                 detail: "\(terminal.surface) link \(link) was never detached"))
            }
        }
    }

    // MARK: Steps

    private mutating func start(visible: Bool, restoring: Bool) {
        guard terminals.count < Self.maxTerminals else { return }
        let machine = Machine(initialSize: Self.sizes[0], visible: visible, restoring: restoring)
        terminals.append(Terminal(surface: "s\(terminals.count + 1)", machine: machine))
        reduce(terminals.count - 1) { _ in .start }
    }

    /// A view event: it reaches only a view still open.
    private mutating func view(_ n: Int, _ make: (inout Terminal) -> Machine.Event?) {
        let open = terminals.indices.filter { !terminals[$0].machine.isClosed }
        guard !open.isEmpty else { return }
        reduce(open[n % open.count], make)
    }

    /// A driver or daemon event: it can reach a view that closed (an open completing late).
    private mutating func driver(_ n: Int, _ make: (inout Terminal) -> Machine.Event?) {
        guard !terminals.isEmpty else { return }
        reduce(n % terminals.count, make)
    }

    private mutating func takeLink() -> Int {
        defer { nextLink += 1 }
        return nextLink
    }

    /// Reduces the event `make` returns (none: the step does nothing), checks it, applies the
    /// effects the driver tracks and journals it.
    private mutating func reduce(_ index: Int, _ make: (inout Terminal) -> Machine.Event?) {
        var terminal = terminals[index]
        guard let event = make(&terminal) else { return }
        let before = terminal.machine
        let effects = terminal.machine.reduce(event)
        violations += terminal.oracle.observe(event, before: before, after: terminal.machine, effects: effects,
                                              surface: terminal.surface)
        switch event {
        case .opened(let link, _): terminal.links.append(link)
        case .replayDelivered(let link): terminal.replayed.insert(link)
        case .ended(let link, _): terminal.ended.insert(link)
        default: break
        }
        for effect in effects {
            switch effect {
            case .open(let attempt, _), .openAfterBackoff(let attempt, _, _): terminal.requested.append(attempt)
            case .detach(let link):
                if fault == .lostDetach, !faultHit {
                    faultHit = true
                } else {
                    terminal.detached.insert(link)
                }
            default: break
            }
        }
        record(event, of: terminal)
        terminals[index] = terminal
    }

    /// The record `InputJournal.attachObserver` writes for `event` (byte counts only).
    private mutating func record(_ event: Machine.Event, of terminal: Terminal) {
        var link: Int?
        var attempt: Int?
        var bytes = 0
        let name: String
        switch event {
        case .start: name = "start"
        case .opened(let opened, let number):
            name = "opened"
            link = opened
            attempt = number
        case .openFailed(let number):
            name = "openFailed"
            attempt = number
        case .replayDelivered(let replayed):
            name = "replay"
            link = replayed
        case .input(let data):
            name = "input"
            bytes = data.count
        case .resize(let size): name = "resize:\(size.cols)x\(size.rows)"
        case .visibility(let visible): name = visible ? "visible" : "hidden"
        case .focused: name = "focused"
        case .takeOver(let setLatest): name = setLatest ? "takeOver:latest" : "takeOver"
        case .gridAnnounced(let announced, let size):
            name = "grid:\(size.cols)x\(size.rows)"
            link = announced
        case .ended(let ended, let reason):
            name = reason == .overflow ? "ended:overflow" : "ended:other"
            link = ended
        case .reconnect: name = "reconnect"
        case .processExited: name = "processExited"
        case .processRevived: name = "processRevived"
        case .close: name = "close"
        }
        let seq = UInt64(journal.count + 1)
        let record = InputJournalEntry.Attach(surface: terminal.surface, event: name, link: link, attempt: attempt, bytes: bytes,
                                              phase: terminal.machine.phase.journalName,
                                              droppedBytes: terminal.machine.droppedInputBytes)
        journal.append(InputJournalEntry(seq: seq, uptimeNanos: seq, window: nil, kind: .attach(record)))
    }

    // MARK: Values

    /// Input chunk `serial`: its first four bytes are the serial, so the oracle tells every chunk
    /// apart by content (A1 compares the bytes sent with the bytes accepted).
    static func chunk(_ serial: UInt32, large: Bool) -> Data {
        var data = Data((0..<4).map { UInt8(truncatingIfNeeded: serial >> (8 * UInt32($0))) })
        data.append(Data(repeating: UInt8(truncatingIfNeeded: serial), count: large ? 1 << 20 : Int(serial % 13)))
        return data
    }

    /// The journal names two end reasons; `connectionLost` would replay as another disconnect
    /// reason, so exact walks leave it out.
    static func closeReason(_ choice: Int, exact: Bool) -> TerminalChannelCloseReason {
        switch choice % (exact ? 3 : 4) {
        case 0: .overflow
        case 1: .surfaceGone
        case 2: .detachedByClient
        default: .connectionLost("walk")
        }
    }

    static func pending(_ machine: Machine) -> Machine.Pending? {
        switch machine.phase {
        case .attaching(let pending), .reattaching(let pending): pending
        default: nil
        }
    }
}
