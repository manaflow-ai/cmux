public import AppKit
public import CmuxNextPages
public import CmuxNextSettings

/// The see-through Chief on a Messages page (`ChiefPanelStyle.seeThrough` and `.seeThroughBar`, 0d682b6e and
/// 94888846): the host half of `ChiefPanelContent.chiefShowsThrough` and `.chiefHeaderHeight`, which the deleted
/// native transcript answered (`HomeNativeTranscriptView.clearsBackground`, `HomeHostView.headerHeight`).
///
/// - The switch: the panel sets ``showsThrough`` while it floats in a see-through style; the page follows it on the
///   `seeThrough` stream (`{showsThrough}`) and then draws no background of its own (seeThrough.ts), so the
///   workspace shows between the bubbles. The page's web view already draws none (`PageWebView.clearBackground`).
/// - The header: the page reports how tall its header is (`seeThrough.header {height}`, CSS px) while see-through,
///   so the panel's header veil ends under it and not over the chat (``headerHeight(zoom:)``, in points).
///
/// The veils behind the bar, the header and the message box stay the panel's (`ChiefPanelView`): they sit behind
/// the web view, over the workspace, which a page backdrop never samples (94888846's capture).
@MainActor
public final class HomeMessagesSeeThrough {
    /// The stream's name and the op's, under `cmux.home.messages.` (``HomeMessagesPageRoute/prefix``).
    public static let stream = "seeThrough"
    public static let headerOp = "seeThrough.header"
    /// The tallest header a page may report, CSS px; a taller report is kept at this.
    static let maxHeaderHeight: Double = 1024

    private let feed: HomePageStream
    /// Whether the page leaves its background clear (the floating Chief's see-through styles). False by default.
    public var showsThrough = false {
        didSet { if showsThrough != oldValue { feed.publish(Self.payload(showsThrough)) } }
    }
    /// The page's header height as it last reported, CSS px; 0 before a report.
    public private(set) var headerCSSHeight: Double = 0
    /// The header's height changed: the panel lays its header veil again.
    public var onHeaderHeight: (@MainActor () -> Void)?

    public init() {
        feed = HomePageStream(initial: Self.payload(false))
    }

    /// The header's height in points for a page at `zoom` (`PageWebView.pageZoom`).
    public func headerHeight(zoom: Double) -> CGFloat { CGFloat(headerCSSHeight * max(zoom, 0.01)) }

    /// The `seeThrough` stream: the switch now and on each change.
    public func subscribe(_ onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription { feed.subscribe(onEvent) }

    /// Answers `seeThrough.header`; nil for any other op.
    public func call(_ name: String, _ fields: [String: JSONValue]) throws -> JSONValue? {
        guard name == Self.headerOp else { return nil }
        guard let height = fields["height"]?.doubleValue, height.isFinite, height >= 0 else {
            throw PageError.invalidParams("height must be a number of CSS pixels")
        }
        let kept = min(height, Self.maxHeaderHeight)
        if kept != headerCSSHeight {
            headerCSSHeight = kept
            onHeaderHeight?()
        }
        return .null
    }

    /// The stream's event.
    static func payload(_ showsThrough: Bool) -> JSONValue { .object(["showsThrough": .bool(showsThrough)]) }

    /// Marks the nearest ancestor of `view` that `matches` (the Chief panel) as needing layout; none matching, nothing.
    public static func relayout(from view: NSView, where matches: (NSView) -> Bool) {
        var ancestor = view.superview
        while let next = ancestor, !matches(next) { ancestor = next.superview }
        ancestor?.needsLayout = true
    }
}
