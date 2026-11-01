import Foundation

/// What the automatic Claude account switch remembers between usage-limit reports, in memory.
///
/// - Accounts it marked exhausted, so a write to the exhaustion file that failed, or a file that
///   later reads as empty, never makes an exhausted account look free again.
/// - How many times it switched each pane since that pane last finished a turn, which caps the
///   attempts at one per other account (spec D4).
/// - When it last switched each pane, so a late report from the replaced Claude is not charged
///   to the account the pane runs now.
/// - When each pane last received input, so an unattended switch never restarts a terminal
///   someone is using.
struct ClaudeAccountAutoSwitchLedger: Equatable, Sendable {
    private var exhaustedUntil: [String: Date] = [:]
    private var switchesSinceTurn: [UUID: Int] = [:]
    private var lastSwitchAtMs: [UUID: Int64] = [:]
    private var lastInputAtMs: [UUID: Int64] = [:]

    /// Whether any pane has switches counted, so turn completions need watching.
    var tracksSwitches: Bool { !switchesSinceTurn.isEmpty }

    /// The accounts exhausted at `now`: the stored entries and the remembered ones whose reset
    /// is still ahead.
    func exhaustedKeys(stored: [String: Date], now: Date) -> Set<String> {
        stored.merging(exhaustedUntil) { max($0, $1) }.reduce(into: []) { keys, entry in
            if entry.value > now { keys.insert(entry.key) }
        }
    }

    /// Remembers that `accountKey` is exhausted until `until`, whether or not the file write works.
    mutating func recordExhaustion(accountKey: String, until: Date) {
        exhaustedUntil[accountKey] = max(until, exhaustedUntil[accountKey] ?? until)
    }

    /// Records input reaching the pane at `atMs` (milliseconds since 1970).
    mutating func noteInput(panelId: UUID, atMs: Int64) {
        lastInputAtMs[panelId] = atMs
    }

    /// Whether the pane received input after `ms`.
    func receivedInput(panelId: UUID, after ms: Int64) -> Bool {
        (lastInputAtMs[panelId] ?? .min) > ms
    }

    /// Counts an automatic switch of the pane that finished at `atMs`.
    mutating func noteAutomaticSwitch(panelId: UUID, atMs: Int64) {
        switchesSinceTurn[panelId, default: 0] += 1
        lastSwitchAtMs[panelId] = atMs
    }

    /// The pane finished a turn on its own: its switches stop counting toward the cap.
    mutating func noteTurnCompleted(panelId: UUID) {
        switchesSinceTurn[panelId] = nil
    }

    /// Automatic switches of the pane since it last finished a turn.
    func automaticSwitches(panelId: UUID) -> Int {
        switchesSinceTurn[panelId] ?? 0
    }

    /// When the pane's last automatic switch finished, in milliseconds since 1970.
    func lastAutomaticSwitchAtMs(panelId: UUID) -> Int64? {
        lastSwitchAtMs[panelId]
    }
}
