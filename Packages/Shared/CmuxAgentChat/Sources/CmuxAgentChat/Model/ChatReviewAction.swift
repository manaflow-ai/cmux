import Foundation

/// A user-authored action on an agent-proposed file edit.
///
/// The action is provider agnostic. The host owns the workspace mutation and
/// the source transports the same request for Claude, Codex, and OpenCode.
public enum ChatReviewAction: String, Sendable, Equatable, Codable {
    case apply
    case revert
    case comment
}
