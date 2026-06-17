/// Where a message sits inside a visual bubble group.
///
/// Consecutive same-author messages close in time share a group; renderers
/// tighten inner corners and show one timestamp per group.
public enum ChatGroupPosition: Sendable, Equatable {
    /// The only message in its group.
    case solo
    /// The first message of a multi-message group.
    case first
    /// An interior message of a multi-message group.
    case middle
    /// The last message of a multi-message group.
    case last
}
