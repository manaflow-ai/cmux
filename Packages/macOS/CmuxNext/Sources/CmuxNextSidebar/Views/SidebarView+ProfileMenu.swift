import AppKit
import CmuxNextDesign

// SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2: the sidebar's bottom-left is
// one control, the current profile's avatar with a chevron. A click (or
// the `sidebar.profileMenu` action) opens the one profile menu the App
// builds from registry actions (`profileMenuProvider`).
extension SidebarView {
    /// The item that draws the profile control, in band order, with its
    /// view: the footer's account item by default.
    var profileControl: (id: LayoutItemID, view: SidebarItemRowView)? {
        for region in bandRegions {
            for row in region.layoutResult.rows {
                guard case .tile(let id, _) = row.kind, let view = region.itemView(id), view.showsAvatar, !view.isHidden else { continue }
                return (id, view)
            }
        }
        return nil
    }

    /// Opens the profile menu over the profile control. Returns false when
    /// the App gave no menu. Without a visible control (a hidden sidebar)
    /// the menu opens at the pointer.
    @discardableResult
    public func showProfileMenu() -> Bool {
        showProfileMenu(from: profileControl?.view)
    }

    @discardableResult
    func showProfileMenu(from anchor: NSView?) -> Bool {
        guard let menu = profileMenuProvider?() else { return false }
        profileMenuPresenter(menu, anchor)
        return true
    }

    /// Pops `menu` up so it opens upward from the control's top edge (the
    /// control sits at the window's bottom), its leading edge on the
    /// control's. The open happens on the next main-actor turn, so a
    /// caller (a socket action, a palette run) returns before the menu's
    /// modal tracking starts.
    static func popUpProfileMenu(_ menu: NSMenu, from anchor: NSView?) {
        // task-owner: none needed; one-shot hop to the next main-actor turn, holds no state
        Task { @MainActor in
            guard let anchor, anchor.window != nil else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }
            let gap = Metrics.space1
            // Flipped anchor: the menu's top-left goes above the control by
            // the menu's height, so the whole menu shows over the footer.
            let origin = NSPoint(x: 0, y: anchor.isFlipped ? -menu.size.height - gap : anchor.bounds.height + menu.size.height + gap)
            menu.popUp(positioning: nil, at: origin, in: anchor)
        }
    }
}
