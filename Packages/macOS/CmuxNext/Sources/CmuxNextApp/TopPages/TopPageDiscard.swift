import AppKit
import CmuxHomeCore

/// How long a hidden top page keeps its view (p07-memory-023). Before this every top page's view
/// stayed for its window's life (about one web content process each); now a page hidden past its
/// policy lets its view go and keeps a ``TopPageViewState``, as a discarded Chrome tab keeps its
/// navigation entries (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc, `Discard`).
nonisolated enum TopPageDiscardPolicy: Hashable, Sendable {
    /// The view stays until the window closes: a page that cannot be built again as it was.
    case never
    /// The view goes once the page has been hidden this long.
    case afterHidden(Duration)

    /// The default of every top page, the internal pages' default (p07-memory-022): 10 minutes hidden.
    static let standard = afterHidden(.seconds(600))
}

/// What a discarded top page keeps so it shows again as the person left it, Chrome's `PageState` of
/// a discarded tab's last entry (third_party/blink/public/common/page_state/page_state.h, which
/// holds each frame's scroll offset and form state) for a native page:
/// - the visible origin of each scroll view (the conversation list, a transcript), by its place in
///   the view tree;
/// - what the page names itself (``selection``: Home's shown conversation).
///
/// Home's composer drafts are the store's (`HomeStore.draft(for:)`, one per conversation), so the
/// rebuilt composer of the selected conversation reads its draft again. Text that no model keeps (a
/// search query, a New Message draft) is form input: the page stays (``TopPageDiscardable``).
nonisolated struct TopPageViewState: Equatable, Sendable {
    /// Each scrolled scroll view's visible origin, keyed by its path from the page's view.
    var scroll: [String: CGPoint] = [:]
    /// The item the page shows (Home: the conversation id).
    var selection: String?
}

/// A page's say in its discard: the provider of an internal top page, or classic Home's view.
/// Every member has a default, so a page that says nothing is discarded on
/// ``TopPageDiscardPolicy/standard`` and comes back with its scroll offsets.
@MainActor
protocol TopPageDiscardable: AnyObject {
    /// When the page's hidden view may go.
    var topPageDiscardPolicy: TopPageDiscardPolicy { get }
    /// The page holds input no model keeps; the planner keeps it at any pressure (the lead rule).
    func holdsUnsavedInput(_ view: NSView) -> Bool
    /// Adds what the page names to the record the host made of `view` (the scroll is in it already).
    func saveViewState(_ view: NSView, into state: inout TopPageViewState)
    /// The rebuilt `view` shows `state`; the host restores the scroll after this.
    func restoreViewState(_ state: TopPageViewState, in view: NSView)
}

extension TopPageDiscardable {
    var topPageDiscardPolicy: TopPageDiscardPolicy { .standard }
    func holdsUnsavedInput(_ view: NSView) -> Bool { false }
    func saveViewState(_ view: NSView, into state: inout TopPageViewState) {}
    func restoreViewState(_ state: TopPageViewState, in view: NSView) {}
}

@MainActor
extension TopPageViewState {
    /// The record of `view`: every scroll view under it that is scrolled away from its origin.
    init(of view: NSView) {
        var offsets: [String: CGPoint] = [:]
        Self.visitScrollViews(in: view, path: "") { scrollView, path in
            let origin = scrollView.contentView.bounds.origin
            if origin != .zero { offsets[path] = origin }
        }
        self.init(scroll: offsets)
    }

    /// Scrolls each scroll view of the rebuilt `view` found at a recorded path back to its origin.
    /// The view must be laid out (its documents sized); a path the new tree lacks is skipped.
    func restoreScroll(in view: NSView) {
        guard !scroll.isEmpty else { return }
        Self.visitScrollViews(in: view, path: "") { scrollView, path in
            if let origin = scroll[path] { scrollView.documentView?.scroll(origin) }
        }
    }

    /// An editable text field under `view` holds text: a search query or a recipient the person typed.
    static func holdsTypedText(_ view: NSView) -> Bool {
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

/// Classic Home follows the top pages' policy: its record names the shown conversation (whose
/// composer draft the store keeps), and a New Message draft keeps the page.
extension TopHomePageView: TopPageDiscardable {
    func holdsUnsavedInput(_ view: NSView) -> Bool {
        newMessage.map { !$0.isEmpty } ?? false
    }

    func saveViewState(_ view: NSView, into state: inout TopPageViewState) {
        state.selection = shown?.rawValue
    }

    func restoreViewState(_ state: TopPageViewState, in view: NSView) {
        guard let selection = state.selection else { return }
        show(ConversationID(selection))
    }
}
