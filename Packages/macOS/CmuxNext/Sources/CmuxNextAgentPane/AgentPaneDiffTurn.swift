public import CmuxNextActions
import Foundation

/// The chat turn a diff open names (`pane.action {id: "openDiffViewer", turn}`, D1 and D2): the
/// turn's checkpoint pair as acpmux recorded it on its `turn_result` (`from` before the prompt,
/// `to` when the turn ended), the repository-relative `file` an edited-files row names, and
/// `show`: the diff tab opens on the turn (a card) or only offers it as Last turn (the header's
/// Changes).
public nonisolated struct AgentPaneDiffTurn: Equatable, Sendable {
    public let from: String
    public let to: String
    public let file: String?
    public let show: Bool

    public init(from: String, to: String, file: String? = nil, show: Bool) {
        self.from = from
        self.to = to
        self.file = file
        self.show = show
    }

    /// Nil unless `params` holds two checkpoint ids; a `file` that is not a relative path inside
    /// the repository is dropped.
    init?(params: Any?) {
        guard let object = params as? [String: Any],
              let from = object["from"] as? String, AgentPaneGitRequest.isCheckpointId(from),
              let to = object["to"] as? String, AgentPaneGitRequest.isCheckpointId(to) else { return nil }
        let file = (object["file"] as? String).flatMap { $0.utf8.count <= 4096 && AgentPaneGitDiffOptions.isInside($0) ? $0 : nil }
        self.init(from: from, to: to, file: file, show: object["show"] as? Bool == true)
    }

    /// The `openDiffViewer` arguments that carry a turn (D1, D2): only the chat header passes them
    /// (the App's AgentChatSplitToggles), and its ViewerHandlers reads them. Not catalog arguments:
    /// a turn's checkpoint ids come from the chat page, and the CLI names none yet.
    public static let fromArgument = "turnFrom", toArgument = "turnTo", fileArgument = "turnFile", showArgument = "turnShow"

    /// This turn as `openDiffViewer` arguments.
    public var actionArguments: [String: ActionValue] {
        var arguments: [String: ActionValue] = [Self.fromArgument: .string(from), Self.toArgument: .string(to), Self.showArgument: .bool(show)]
        if let file { arguments[Self.fileArgument] = .string(file) }
        return arguments
    }
}

/// The turn's own changes a diff open carries (`pane.action {id: "openDiffViewer", patch: {text,
/// file?}}`) where the chat folder's diff cannot show them: a folder in no repository, or a turn that
/// wrote a file outside it. `text` is unified patch text the chat built from the turn's tool calls,
/// shown read-only in a diff tab beside the chat; `file`, the patch's name of the file it scrolls to.
public nonisolated struct AgentPaneDiffPatch: Equatable, Sendable {
    /// The longest patch a chat may hand the tab.
    public static let maximumBytes = 16 << 20

    public let text: String
    public let file: String?

    public init(text: String, file: String? = nil) {
        self.text = text
        self.file = file
    }

    /// Nil unless `params` holds patch text (non-empty, at most ``maximumBytes``, with a git file
    /// header); a `file` that is empty, too long or holds NUL is dropped.
    init?(params: Any?) {
        guard let object = params as? [String: Any], let text = object["text"] as? String,
              (1...Self.maximumBytes).contains(text.utf8.count), text.hasPrefix("diff --git ") else { return nil }
        let file = (object["file"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\u{0}") ? $0 : nil }
        self.init(text: text, file: file)
    }

    /// The `openDiffViewer` arguments that carry a patch, as ``AgentPaneDiffTurn``'s carry a turn.
    public static let textArgument = "turnPatch", fileArgument = "turnPatchFile"

    /// This patch as `openDiffViewer` arguments.
    public var actionArguments: [String: ActionValue] {
        var arguments: [String: ActionValue] = [Self.textArgument: .string(text)]
        if let file { arguments[Self.fileArgument] = .string(file) }
        return arguments
    }
}
