import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Deterministic replay of an input journal against the pure reducers
/// (plans/cmux-next/input-spec.md section 5). Each window's focus machine
/// starts at its first checkpoint and reduces the journaled events; each
/// terminal's attach machine starts at its journaled `start`. After every
/// step the replay compares the recorded outcome and checks the model,
/// transition, routing and attach invariants, and reports the first
/// divergence. Run it on a desync report to see whether the current
/// reducers still produce the recorded (bad) outcome.
nonisolated enum InputReplay {
    struct Divergence: Hashable, Sendable, Codable {
        enum Kind: String, Hashable, Sendable, Codable {
            /// The reducer produced a different outcome than recorded.
            case outcome
            /// A checkpoint disagrees with the replayed state.
            case checkpoint
            /// The replayed step breaks an invariant.
            case invariant
        }

        var kind: Kind
        var seq: UInt64
        var window: String?
        var event: String
        var recorded: String?
        var replayed: String?
        var violations: [InputViolation] = []
    }

    struct Result: Hashable, Sendable, Codable {
        var focusEvents = 0
        var attachEvents = 0
        var windows: [String] = []
        /// Focus events before a window's first checkpoint (not replayable).
        var skippedFocusEvents = 0
        /// Attach events of terminals whose `start` the ring overwrote.
        var skippedAttachEvents = 0
        var firstDivergence: Divergence?
        var divergences = 0
    }

    private struct Terminal {
        var machine = TerminalAttachMachine<Int>(initialSize: CellSize(cols: 80, rows: 24))
        var oracle = AttachOracle<Int>()
        var chunk: UInt8 = 0
    }

    static func replay(_ entries: [InputJournalEntry]) -> Result {
        var result = Result()
        var states: [String: FocusState] = [:]
        var terminals: [String: Terminal] = [:]
        func diverge(_ divergence: Divergence) {
            result.divergences += 1
            if result.firstDivergence == nil { result.firstDivergence = divergence }
        }
        for entry in entries {
            let window = entry.window ?? "-"
            switch entry.kind {
            case .focusCheckpoint(let checkpoint):
                if let state = states[window], state != checkpoint {
                    diverge(Divergence(kind: .checkpoint, seq: entry.seq, window: window, event: "checkpoint",
                                       recorded: String(describing: FocusDigest(checkpoint)), replayed: String(describing: FocusDigest(state))))
                }
                if states[window] == nil { result.windows.append(window) }
                states[window] = checkpoint
            case .focus(let event, let recorded):
                guard let state = states[window] else {
                    result.skippedFocusEvents += 1
                    continue
                }
                result.focusEvents += 1
                let next = FocusReducer.reduce(state, event).0
                let digest = FocusDigest(next)
                if digest != recorded {
                    diverge(Divergence(kind: .outcome, seq: entry.seq, window: window, event: String(describing: event),
                                       recorded: String(describing: recorded), replayed: String(describing: digest)))
                }
                let violations = InputInvariants.step(from: state, event, to: next, window: window)
                if !violations.isEmpty {
                    diverge(Divergence(kind: .invariant, seq: entry.seq, window: window, event: String(describing: event),
                                       violations: violations))
                }
                states[window] = next
            case .attach(let record):
                if record.event == "start" { terminals[record.surface] = Terminal() }
                guard var terminal = terminals[record.surface], let event = attachEvent(record, chunk: &terminal.chunk) else {
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
        default:
            if let size = cellSize(event, prefix: "resize:") { return .resize(size) }
            if let size = cellSize(event, prefix: "grid:") { return record.link.map { .gridAnnounced($0, size) } }
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
