/// The launch's first live content frame: a pane's first frame of its own live content in a
/// visible window, not a saved picture. The first of them is also `first_live_content_frame`, Chrome's
/// `RecordFirstWebContentsNonEmptyPaint` (components/startup_metric_utils/browser/startup_metric_utils.h).
///
/// ```swift
/// if let derived = LaunchMarks.derivedMark(of: "first_terminal_frame") { mark(derived) } // first_live_content_frame
/// ```
extension LaunchMarks {
    /// The marks of a pane's first live content frame: the terminal's first frame after the daemon's content
    /// reached its surface (`LaunchSettle`), a page's first paint in a shown pane (`first_page_frame`).
    public static let liveContentFrameMarks: Set<String> = ["first_terminal_frame", "first_page_frame"]
    /// The mark the first of ``liveContentFrameMarks`` also records, at the same time.
    public static let liveContentFrame = "first_live_content_frame"

    /// The mark a first record of `name` also makes at the same time (``liveContentFrame`` for a live content
    /// frame), or nil. Its owner records it as it records `name`, so it too lands once, at the first of them.
    public static func derivedMark(of name: String) -> String? {
        liveContentFrameMarks.contains(name) ? liveContentFrame : nil
    }

    /// Whether `name` was recorded.
    public func contains(_ name: String) -> Bool { all.contains { $0.name == name } }
}
