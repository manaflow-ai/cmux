public import AppKit

/// How long a hidden page keeps its view (top pages; 022: internal page tabs).
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
/// - the visible origin of each scroll view (a list), by its place in the view tree or a name the
///   page gives it;
/// - what the page names itself (``selection``: Home's shown conversation, whose composer draft
///   its store keeps);
/// - the search query the person typed (``search``).
///
/// Input the record cannot hold (a draft no store keeps) is form input: the page stays instead
/// (``PageDiscardable/holdsUnsavedInput(_:)``).
public nonisolated struct PageViewState: Equatable, Sendable {
    /// Each scrolled scroll view's visible origin, keyed by its path from the page's view.
    public var scroll: [String: CGPoint]
    /// The item the page shows (Home: the conversation id).
    public var selection: String?
    /// The page's search query; nil when none is typed.
    public var search: String?

    public init(scroll: [String: CGPoint] = [:], selection: String? = nil, search: String? = nil) {
        self.scroll = scroll
        self.selection = selection
        self.search = search
    }
}

/// A page's say in its discard: a page provider, or a native page's view. Only a page with an
/// owner is ever discarded; a page without one stays for its window's life, since nothing would
/// record or restore what it shows. An owner that says nothing more goes on
/// ``PageDiscardPolicy/standard``, is kept while an editable field holds text, and comes back with
/// its scroll offsets.
@MainActor
public protocol PageDiscardable: AnyObject {
    /// When the page's hidden view may go.
    var pageDiscardPolicy: PageDiscardPolicy { get }
    /// The page holds input its record does not keep; the discard planner keeps it at any pressure
    /// (the lead rule).
    func holdsUnsavedInput(_ view: NSView) -> Bool
    /// Adds what the page names to the record made of `view` (its scroll offsets are in it already).
    func saveViewState(_ view: NSView, into state: inout PageViewState)
    /// The rebuilt `view`, now the window's content, shows `state`. A page whose content arrives
    /// later (a list its store fills) applies its scroll once that content exists.
    func restoreViewState(_ state: PageViewState, in view: NSView)
}

extension PageDiscardable {
    public var pageDiscardPolicy: PageDiscardPolicy { .standard }
    public func holdsUnsavedInput(_ view: NSView) -> Bool { PageViewState.holdsTypedText(view) }
    public func saveViewState(_ view: NSView, into state: inout PageViewState) {}
    /// A page built whole in its initializer: the scroll offsets once it is laid out.
    public func restoreViewState(_ state: PageViewState, in view: NSView) {
        // sync-layout: restoreScroll below reads the rebuilt documents' laid-out sizes.
        view.layoutSubtreeIfNeeded()
        state.restoreScroll(in: view)
    }
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
