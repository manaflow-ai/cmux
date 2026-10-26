public import AppKit

/// How long a hidden page keeps its view (p07-memory-023: top pages; 022: internal page tabs).
/// A page hidden past its policy lets its view go and keeps a ``PageViewState``, as a discarded
/// Chrome tab keeps its navigation entries (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc,
/// `Discard`).
public nonisolated enum PageDiscardPolicy: Hashable, Sendable {
    /// The view stays until its window closes: a page that cannot be built again as it was.
    case never
    /// The view goes once the page has been hidden this long.
    case afterHidden(Duration)

    /// Every cmux page's default: 10 minutes hidden (p07-memory.md, task 022).
    public static let standard = afterHidden(.seconds(600))
}

/// What a discarded page keeps so it shows again as the person left it, Chrome's `PageState` of a
/// discarded tab's last entry (third_party/blink/public/common/page_state/page_state.h, which holds
/// each frame's scroll offset and form state) for a native page:
/// - the visible origin of each scroll view (a list, a transcript), by its place in the view tree;
/// - what the page names itself (``selection``: Home's shown conversation).
///
/// Text that no model keeps (a search query, a draft no store holds) is form input: the page
/// stays instead (``PageDiscardable/holdsUnsavedInput(_:)``, ``holdsTypedText(_:)``).
public nonisolated struct PageViewState: Equatable, Sendable {
    /// Each scrolled scroll view's visible origin, keyed by its path from the page's view.
    public var scroll: [String: CGPoint]
    /// The item the page shows (Home: the conversation id).
    public var selection: String?

    public init(scroll: [String: CGPoint] = [:], selection: String? = nil) {
        self.scroll = scroll
        self.selection = selection
    }
}

/// A page's say in its discard: a page provider, or a native page's view. Every member has a
/// default, so a page that says nothing goes on ``PageDiscardPolicy/standard`` and comes back with
/// its scroll offsets.
@MainActor
public protocol PageDiscardable: AnyObject {
    /// When the page's hidden view may go.
    var pageDiscardPolicy: PageDiscardPolicy { get }
    /// The page holds input no model keeps; the discard planner keeps it at any pressure (the lead rule).
    func holdsUnsavedInput(_ view: NSView) -> Bool
    /// Adds what the page names to the record made of `view` (the scroll is in it already).
    func saveViewState(_ view: NSView, into state: inout PageViewState)
    /// The rebuilt `view` shows `state`; the scroll is restored after this.
    func restoreViewState(_ state: PageViewState, in view: NSView)
}

extension PageDiscardable {
    public var pageDiscardPolicy: PageDiscardPolicy { .standard }
    public func holdsUnsavedInput(_ view: NSView) -> Bool { false }
    public func saveViewState(_ view: NSView, into state: inout PageViewState) {}
    public func restoreViewState(_ state: PageViewState, in view: NSView) {}
}

@MainActor
extension PageViewState {
    /// The record of `view`: every scroll view under it that is scrolled away from its origin.
    public init(of view: NSView) {
        var offsets: [String: CGPoint] = [:]
        Self.visitScrollViews(in: view, path: "") { scrollView, path in
            let origin = scrollView.contentView.bounds.origin
            if origin != .zero { offsets[path] = origin }
        }
        self.init(scroll: offsets)
    }

    /// Scrolls each scroll view of the rebuilt `view` found at a recorded path back to its origin.
    /// The view must be laid out (its documents sized); a path the new tree lacks is skipped.
    public func restoreScroll(in view: NSView) {
        guard !scroll.isEmpty else { return }
        Self.visitScrollViews(in: view, path: "") { scrollView, path in
            if let origin = scroll[path] { scrollView.documentView?.scroll(origin) }
        }
    }

    /// An editable text field under `view` holds text: a search query or a recipient the person typed.
    public static func holdsTypedText(_ view: NSView) -> Bool {
        view.subviews.contains { child in
            if let field = child as? NSTextField, field.isEditable, !field.stringValue.isEmpty { return true }
            return holdsTypedText(child)
        }
    }

    /// Each scroll view under `view`, depth first, with its path: one component per level, the
    /// view's accessibility identifier when it has one, else its index among its siblings.
    private static func visitScrollViews(in view: NSView, path: String, _ visit: (NSScrollView, String) -> Void) {
        for (index, child) in view.subviews.enumerated() {
            let name = child.accessibilityIdentifier()
            let childPath = path + "/" + (name.isEmpty ? String(index) : name)
            if let scrollView = child as? NSScrollView { visit(scrollView, childPath) }
            visitScrollViews(in: child, path: childPath, visit)
        }
    }
}
