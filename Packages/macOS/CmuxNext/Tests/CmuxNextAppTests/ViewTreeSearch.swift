import AppKit

/// Finds views by accessibility identifier in a native view tree (a scroll view's document too),
/// for the suites that still test AppKit panels (JoinConsentTests).
@MainActor
struct ViewTreeSearch {
    static func identifiers(_ view: NSView) -> [String] {
        [view.accessibilityIdentifier()] + view.subviews.flatMap(identifiers)
    }

    static func find(_ view: NSView, id: String) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews { if let hit = find(sub, id: id) { return hit } }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView { return find(doc, id: id) }
        return nil
    }
}
