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
}
