/// What one pane last reported to its window's focus as presented (``FocusEvent/contentPresented(pane:)``),
/// so it reports a change of what it shows once, not each show of the same content.
///
/// The event makes the window's focus apply again once the content its target names is there (the
/// applier waits for the pane's tab, its content view and the pane in a window). A show of the same
/// tab with the same views changes none of that: reporting it again reduces focus for nothing. A pane
/// shows its selection again on every strip update (a title, a busy dot, the next frame of the
/// presentation scheduler), so a strip that updated every frame reduced focus every frame while idle
/// (NEWTAB PER-FRAME: a New Tab page sent 272 of the input journal's 300 entries, one per 16.7 ms).
///
/// The views are held weakly and compared by identity: a view made again for the same tab is a change.
///
/// ```swift
/// var report = PresentedContentReport()
/// report.changes(tab: "a", views: [page, window], replacing: nil) // true: the first show
/// report.changes(tab: "a", views: [page, window], replacing: "a") // false: the same content again
/// report.changes(tab: "a", views: [page, window], replacing: nil) // true: the pane had let it go
/// ```
public nonisolated struct PresentedContentReport {
    private struct Held {
        weak var object: AnyObject?
    }

    private var tab: String?
    private var views: [Held]?

    public init() {}

    /// Whether showing `tab` with `views` (its content view, the window: nil where there is none) is a
    /// change from what was last reported; when it is, it becomes the last report.
    ///
    /// - Parameters:
    ///   - tab: The tab the pane shows now, nil for none.
    ///   - views: What the focus applier needs of it, in a fixed order.
    ///   - shown: The tab the pane showed before this show (nil: none, or it let its content go): a
    ///     show that replaces another tab, or none, is a change whatever was reported.
    /// - Returns: True when the pane should report its content presented.
    public mutating func changes(tab: String?, views: [AnyObject?], replacing shown: String?) -> Bool {
        if shown == tab, let held = self.views, self.tab == tab, held.count == views.count,
           zip(held, views).allSatisfy({ $0.object === $1 }) {
            return false
        }
        self.tab = tab
        self.views = views.map { Held(object: $0) }
        return true
    }
}
