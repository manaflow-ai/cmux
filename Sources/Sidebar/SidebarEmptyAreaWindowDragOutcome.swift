/// Result of tracking one empty-area mouse-down sequence.
enum SidebarEmptyAreaWindowDragOutcome: Equatable {
    /// The caller should continue its normal `mouseDown` handling.
    case passThrough
    /// AppKit took ownership of the sequence to move the window.
    case dragged
    /// AppKit ended the sequence without a mouse-up to replay.
    case cancelled
}
