import AppKit

/// The accessibility hit test of a sidebar row whose hover controls clear by paint (HOVER COMMIT 2). A cleared control
/// (in the tree, at opacity 0) is no hit: the point answers what it answered while the control was hidden, the
/// frontmost other subview under it, else the row (or its nearest ancestor that is an accessibility element).
/// AppKit calls `accessibilityHitTest` nonisolated; this adapter is the one hop to the main actor that reads the row.
nonisolated struct RowAccessibilityHitTest: Sendable {
    let row: SidebarRowView

    /// What the hit test answers in place of a cleared hover control.
    nonisolated enum Answer: Sendable {
        /// AppKit's own hit is no cleared control.
        case kept
        /// The frontmost other subview under the point answers.
        case subview(NSView)
        /// Nothing else is under the point: this element answers.
        case element(NSView)
    }

    /// `hit` (AppKit's answer at the screen `point`), or what stands in for it when it is a cleared control.
    func answer(_ hit: Any?, at point: NSPoint) -> Any? {
        guard Thread.isMainThread else { return hit }
        // Only the view or cell crosses to the main actor (both are main-actor classes, so Sendable); any other
        // element is no control.
        let (view, cell) = (hit as? NSView, hit as? NSCell)
        guard view != nil || cell != nil else { return hit }
        // main-proof: checked Thread.isMainThread above (AppKit asks accessibility on the main thread)
        switch MainActor.assumeIsolated({ resolve(view ?? cell?.controlView, at: point) }) {
        case .kept: return hit
        case .subview(let view): return view.accessibilityHitTest(point)
        case .element(let view): return view
        }
    }

    /// `owner`: the view AppKit's hit stands for.
    @MainActor private func resolve(_ owner: NSView?, at point: NSPoint) -> Answer {
        let clear = row.clearHoverControls
        func isClear(_ owner: NSView?) -> Bool {
            guard let owner else { return false }
            return clear.contains { owner === $0 || owner.isDescendant(of: $0) }
        }
        guard !clear.isEmpty, isClear(owner) else { return .kept }
        if let window = row.window {
            let local = row.convert(window.convertPoint(fromScreen: point), from: nil)
            for sub in row.subviews.reversed() where !sub.isHidden && !clear.contains(where: { $0 === sub }) && sub.frame.contains(local) {
                if !isClear(row.accessibilityView(of: sub.accessibilityHitTest(point))) { return .subview(sub) }
            }
        }
        var element: NSView = row
        while !element.isAccessibilityElement(), let up = element.superview { element = up }
        return .element(element)
    }
}
