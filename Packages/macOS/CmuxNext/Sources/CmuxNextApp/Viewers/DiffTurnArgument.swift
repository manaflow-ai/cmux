import CmuxNextActions
import CmuxNextAgentPane

/// The arguments a chat's `openDiffViewer` run carries for its turn (D1, D2): the checkpoint pair,
/// the edited file and whether the tab opens on the turn. Only the chat header passes them
/// (``AgentChatSplitToggles``); ``ViewerHandlers`` reads them. Not catalog arguments: a turn's
/// checkpoint ids come from the chat page, and the CLI names none yet.
enum DiffTurnArgument {
    static let from = "turnFrom"
    static let to = "turnTo"
    static let file = "turnFile"
    static let show = "turnShow"

    /// `turn` as `openDiffViewer` arguments.
    static func arguments(_ turn: AgentPaneDiffTurn) -> [String: ActionValue] {
        var arguments: [String: ActionValue] = [from: .string(turn.from), to: .string(turn.to), show: .bool(turn.show)]
        if let path = turn.file { arguments[file] = .string(path) }
        return arguments
    }
}
