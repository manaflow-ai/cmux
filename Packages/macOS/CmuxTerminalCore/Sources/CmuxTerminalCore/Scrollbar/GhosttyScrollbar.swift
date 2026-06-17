public import GhosttyKit

/// A snapshot of the runtime's scrollback geometry, in rows.
///
/// Mirrors the `ghostty_action_scrollbar_s` payload that the runtime posts on
/// every scrollback change; the surface view converts it into scroller
/// position and knob proportion.
public struct GhosttyScrollbar: Sendable {
    /// The total scrollback height, in rows.
    public let total: UInt64

    /// The viewport's offset from the top of scrollback, in rows.
    public let offset: UInt64

    /// The viewport height, in rows.
    public let len: UInt64

    /// Creates a snapshot from the runtime's C action payload.
    ///
    /// - Parameter c: The scrollbar action payload from libghostty.
    public init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}
