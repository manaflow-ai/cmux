public import Foundation

/// A column in the Kanban board's task pipeline.
///
/// Models the autonomous-board lifecycle (inspired by the CNVS "Forge"): tasks
/// move `backlog → ready → building → testing → done`, with `blocked` and
/// `failed` as off-pipeline exception states that wait for human intervention
/// or a retry.
///
/// Decoding is tolerant: an unknown raw value (e.g. a column added by a newer
/// build, then read back by an older one) falls back to ``backlog`` rather than
/// throwing, so a persisted board never fails to load over a schema bump.
public enum KanbanColumn: String, CaseIterable, Codable, Sendable {
    case backlog
    case ready
    case building
    case testing
    case done
    case blocked
    case failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanColumn(rawValue: raw) ?? .backlog
    }

    /// Whether a card in this column is actively occupying a dispatch slot
    /// (counts against the board's WIP limit).
    public var occupiesWipSlot: Bool {
        switch self {
        case .building, .testing:
            return true
        case .backlog, .ready, .done, .blocked, .failed:
            return false
        }
    }

    /// Whether this is a terminal column (no further automatic transition).
    public var isTerminal: Bool {
        switch self {
        case .done, .failed:
            return true
        case .backlog, .ready, .building, .testing, .blocked:
            return false
        }
    }
}
