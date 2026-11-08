import AppKit
import CmuxNextDesign

/// The Pinned item views an unpin took out of a region, parked hidden in it by workspace, so the workspace's next pin
/// moves the same `SidebarItemRowView` again (cmux-ad m70: one copy, the same view; Chromium's tab strip moves the same
/// tab view to its new bounds). A new view cost the pin's frame: AppKit builds its layer tree at the display flush and
/// frees the old one there (pin profile, cmux21 120 Hz, cb761d6: the flush was 5.2 ms of the pin's second turn, the
/// largest cut). The list parks its rows the same way (`SidebarListView.recycle`: hidden in place, never out of the
/// window). The app mints a new item id on each pin (`SidebarLayoutDocument.pinOp`), so the key is the workspace.
@MainActor
struct SidebarParkedItems {
    /// Parked views kept; past this the oldest leaves the window.
    static let limit = 8
    private var views: [WorkspaceID: SidebarItemRowView] = [:]
    private var order: [WorkspaceID] = []

    /// `workspace`'s parked view, out of the park; nil when none waits.
    mutating func take(_ workspace: WorkspaceID?) -> SidebarItemRowView? {
        guard let workspace, let view = views.removeValue(forKey: workspace) else { return nil }
        order.removeAll { $0 == workspace }
        return view
    }

    /// Parks `view` for `workspace`; returns the views that leave the park (one it replaced, the oldest past `limit`).
    mutating func put(_ view: SidebarItemRowView, for workspace: WorkspaceID) -> [SidebarItemRowView] {
        var leaving: [SidebarItemRowView] = []
        if let replaced = views.updateValue(view, forKey: workspace) {
            if replaced !== view { leaving.append(replaced) }
            order.removeAll { $0 == workspace }
        }
        order.append(workspace)
        while order.count > Self.limit {
            if let old = views.removeValue(forKey: order.removeFirst()) { leaving.append(old) }
        }
        return leaving
    }
}

extension SidebarRegionView {
    /// An item view this region stops drawing. A workspace's item at rest parks hidden in place for that workspace's
    /// next pin (`SidebarParkedItems`): no move left on it, no press, not the first responder. Any other item, or one a
    /// flight still raises (its landing puts back the ground it saved), leaves the window as before.
    func park(_ view: SidebarItemRowView) {
        guard let workspace = view.info.workspace, (view.layer?.zPosition ?? 0) == 0, view.superview === self else {
            return view.removeFromSuperview()
        }
        if let window, window.firstResponder === view { window.makeFirstResponder(nil) }
        view.endPress()
        view.isHidden = true
        for layer in [view.layer, view.title.layer, view.pinGlyph?.layer].compactMap({ $0 }) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("\(SidebarDragSpring.batchKey).") {
                layer.removeAnimation(forKey: key)
            }
        }
        for leaving in parkedItems.put(view, for: workspace) where leaving.superview === self { leaving.removeFromSuperview() }
    }

    /// The parked item view of `workspace`, shown again at full opacity (the caller configures and places it); nil when
    /// none waits.
    func unparkItem(_ workspace: WorkspaceID?) -> SidebarItemRowView? {
        guard let view = parkedItems.take(workspace) else { return nil }
        Motion.withoutAnimation {
            view.isHidden = false
            view.alphaValue = 1
        }
        return view
    }
}
