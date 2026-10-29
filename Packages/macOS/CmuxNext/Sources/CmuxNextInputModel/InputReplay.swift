import CmuxNextDaemon
package import CmuxNextFocus
import Foundation

/// Deterministic replay of an input journal against the pure reducers
/// (plans/cmux-next/input-spec.md section 5). Each window's focus machine
/// starts at its first checkpoint and reduces the journaled events; each
/// terminal's attach machine starts at its journaled `start`. After every
/// step the replay compares the recorded outcome and checks the model,
/// transition, routing and attach invariants, and reports the first
/// divergence. Run it on a desync report to see whether the current
/// reducers still produce the recorded (bad) outcome.
///
/// The replay is a value over the entries it is given (the app's ring, a
/// desync report's journal or a saved file): it reads no journal itself, so
/// `debug.replay` and an offline replayer give the same `Result` for the
/// same entries and rules.
///
/// The key routing (K) rules ask the App's `KeyRouter`, which this module
/// cannot see, so the caller passes them as `focusRules`; the model (F) and
/// transition (T) rules run here for every caller.
package nonisolated struct InputReplay: Sendable {
    package struct Divergence: Hashable, Sendable, Codable {
        package enum Kind: String, Hashable, Sendable, Codable {
            /// The reducer produced a different outcome than recorded.
            case outcome
            /// A checkpoint disagrees with the replayed state.
            case checkpoint
            /// The replayed step breaks an invariant.
            case invariant
        }

        package var kind: Kind
        package var seq: UInt64
        package var window: String?
        package var event: String
        package var recorded: String?
        package var replayed: String?
        package var violations: [InputViolation] = []
    }

    package struct Result: Hashable, Sendable, Codable {
        package var focusEvents = 0
        package var attachEvents = 0
        package var windows: [String] = []
        /// Focus events before a window's first checkpoint (not replayable).
        package var skippedFocusEvents = 0
        /// Attach events of terminals whose `start` the ring overwrote.
        package var skippedAttachEvents = 0
        package var firstDivergence: Divergence?
        package var divergences = 0
    }

    private struct Terminal {
        var machine = TerminalAttachMachine<Int>(initialSize: CellSize(cols: 80, rows: 24))
        var oracle = AttachOracle<Int>()
        var chunk: UInt8 = 0
    }

    /// Extra rules checked on each focus state a reduction produces, after
    /// the model and transition rules (the App passes its key routing rules).
    package typealias FocusRules = @Sendable (_ state: FocusState, _ window: String?) -> [InputViolation]

    /// The journal to replay, oldest first.
    package var entries: [InputJournalEntry]
    package var focusRules: FocusRules

    package init(_ entries: [InputJournalEntry], focusRules: @escaping FocusRules = { _, _ in [] }) {
        self.entries = entries
        self.focusRules = focusRules
    }

    /// Reduces every entry in order and reports what it found.
    package func run() -> Result {
        var result = Result()
        var machines: [String: (machine: FocusMachine, state: FocusState)] = [:]
        var terminals: [String: Terminal] = [:]
        func diverge(_ divergence: Divergence) {
            result.divergences += 1
            if result.firstDivergence == nil { result.firstDivergence = divergence }
        }
        for entry in entries {
            let window = entry.window ?? "-"
            switch entry.kind {
            case .focusCheckpoint(let checkpoint):
                let machine = machines[window]?.machine ?? FocusMachine()
                if let replayed = machines[window], !replayed.machine.checkpoint().matches(checkpoint) {
                    diverge(Divergence(kind: .checkpoint, seq: entry.seq, window: window, event: "checkpoint",
                                       recorded: checkpoint.json, replayed: replayed.machine.checkpoint().json))
                }
                guard let state = machine.restore(checkpoint) else {
                    machines[window] = nil
                    continue
                }
                if !result.windows.contains(window) { result.windows.append(window) }
                machines[window] = (machine, state)
            case .focus(let event, let recorded):
                guard let replaying = machines[window] else {
                    result.skippedFocusEvents += 1
                    continue
                }
                let (machine, state) = (replaying.machine, replaying.state)
                result.focusEvents += 1
                var next = state
                _ = machine.send(event, into: &next)
                let digest = FocusDigest(next)
                if digest != recorded {
                    diverge(Divergence(kind: .outcome, seq: entry.seq, window: window, event: String(describing: event),
                                       recorded: String(describing: recorded), replayed: String(describing: digest)))
                }
                let violations = InputInvariants.reduction(from: state, event, to: next, window: window)
                    + focusRules(next, window)
                if !violations.isEmpty {
                    diverge(Divergence(kind: .invariant, seq: entry.seq, window: window, event: String(describing: event),
                                       violations: violations))
                }
                machines[window] = (machine, next)
            case .attach(let record):
                if record.event == "start" { terminals[record.surface] = Terminal() }
                guard var terminal = terminals[record.surface], let event = Self.attachEvent(record, chunk: &terminal.chunk) else {
                    result.skippedAttachEvents += 1
                    continue
                }
                result.attachEvents += 1
                let before = terminal.machine
                let effects = terminal.machine.reduce(event)
                let violations = terminal.oracle.observe(event, before: before, after: terminal.machine, effects: effects,
                                                         surface: record.surface)
                if terminal.machine.phase.journalName != record.phase {
                    diverge(Divergence(kind: .outcome, seq: entry.seq, window: nil, event: "\(record.surface) \(record.event)",
                                       recorded: record.phase, replayed: terminal.machine.phase.journalName))
                }
                if !violations.isEmpty {
                    diverge(Divergence(kind: .invariant, seq: entry.seq, window: nil, event: "\(record.surface) \(record.event)",
                                       violations: violations))
                }
                terminals[record.surface] = terminal
            default:
                break
            }
        }
        return result
    }

    /// The machine event a journaled attach record stands for. Input gets
    /// distinct synthetic bytes of the recorded length, so the oracle can
    /// still tell chunks apart.
    private static func attachEvent(_ record: InputJournalEntry.Attach, chunk: inout UInt8) -> TerminalAttachMachine<Int>.Event? {
        let event = record.event
        switch event {
        case "start": return .start
        case "opened": return record.link.flatMap { link in record.attempt.map { .opened(link, attempt: $0) } }
        case "openFailed": return record.attempt.map { .openFailed(attempt: $0) }
        case "replay": return record.link.map { .replayDelivered($0) }
        case "input":
            chunk &+= 1
            return .input(Data(repeating: chunk, count: record.bytes))
        case "visible": return .visibility(true)
        case "hidden": return .visibility(false)
        case "close": return .close
        case "reconnect": return .reconnect
        case "processExited": return .processExited
        case "processRevived": return .processRevived
        case "ended:overflow": return record.link.map { .ended($0, .overflow) }
        case "ended:other": return record.link.map { .ended($0, .surfaceGone) }
        case "focused": return .focused
        case "takeOver": return .takeOver(setLatest: false)
        case "takeOver:latest": return .takeOver(setLatest: true)
        default:
            if let size = Self.cellSize(event, prefix: "resize:") { return .resize(size) }
            if let size = Self.cellSize(event, prefix: "grid:") { return record.link.map { .gridAnnounced($0, size) } }
            return nil
        }
    }

    /// `<prefix><cols>x<rows>`.
    private static func cellSize(_ event: String, prefix: String) -> CellSize? {
        guard event.hasPrefix(prefix) else { return nil }
        let parts = event.dropFirst(prefix.count).split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? CellSize(cols: parts[0], rows: parts[1]) : nil
    }
}

extension InputInvariants {
    /// The model and transition checks for one replayed reduction; `InputReplay`
    /// adds its caller's `focusRules` (the App's key routing rules).
    nonisolated static func reduction(from old: FocusState, _ event: FocusEvent, to new: FocusState,
                                      window: String?) -> [InputViolation] {
        model(new, window: window) + transition(from: old, event, to: new, window: window)
    }
}
