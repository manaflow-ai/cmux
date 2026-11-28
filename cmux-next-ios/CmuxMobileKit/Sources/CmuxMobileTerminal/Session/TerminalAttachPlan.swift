import Foundation

/// How a terminal page's attach reaches the Mac (Leo, 2026-11-17, softened:
/// "Surely we can just calculate a terminal size and resize whatever needs
/// exceptions, falling back if need be. Plus the loading of everything needs
/// to be FASTER.").
///
/// The phone already knows its grid before the attach goes out: the page
/// measures it from the view's size. A first attach sends it with the attach,
/// in the same write as `set-client-info` and `identify`, so the Mac answers
/// with the replay at that grid one round trip after the start, not two. The
/// Mac's answer is the exception: a grid it keeps (its own window, a smaller
/// viewer) comes back as its own and is handled as before, and an attach it
/// refuses (a Mac older than the sized attach) falls back to the attach in
/// series, `identify` first.
public enum TerminalAttachPlan: Equatable, Sendable {
    /// `set-client-info`, `identify` and `attach-surface {cols, rows}` in one
    /// write: one round trip to the first frame at the phone's grid.
    case pipelined(columns: Int, rows: Int)
    /// `set-client-info` and `identify`, then `attach-surface` with what
    /// `identify` listed: two round trips. A reattach (it first asks where
    /// the terminal is, and may resume a stream from the frame it drew), a
    /// hidden terminal (it claims no size) or a page with no grid yet.
    case sequential

    /// `firstAttach`: this session never attached and is not retrying.
    /// `claimsSize`: the terminal is on screen. `size`: the grid the page
    /// measured, if any. `resumes`: the attach resumes a stream.
    public static func plan(firstAttach: Bool, claimsSize: Bool, size: (columns: Int, rows: Int)?,
                            resumes: Bool = false) -> TerminalAttachPlan {
        guard firstAttach, claimsSize, !resumes, let size, size.columns > 0, size.rows > 0 else { return .sequential }
        return .pipelined(columns: size.columns, rows: size.rows)
    }

    /// Round trips from the start to the Mac's answer to the attach.
    public var roundTrips: Int {
        switch self {
        case .pipelined: 1
        case .sequential: 2
        }
    }
}
