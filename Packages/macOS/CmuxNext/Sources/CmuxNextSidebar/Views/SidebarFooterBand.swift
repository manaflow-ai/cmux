import AppKit
import CmuxNextDesign

/// The sidebar's bottom band: the footer's accessory slots, the profile
/// control's menu and where the spaces dots sit. Its views stay the
/// sidebar's (`footer`, `profileBar`, `footerRegion`); this places them.
///
/// The footer never shows Back (Lawrence 2026-10-09): leaving a page is the
/// page's own job or the titlebar's Go Back (SidebarFooterHasNoBackTests).
@MainActor
final class SidebarFooterBand {
    private weak var host: SidebarView?
    /// Opens the profile menu over its anchor (tests swap it).
    var profileMenuPresenter: @MainActor (NSMenu, NSView?) -> Void = { SidebarFooterBand.popUpProfileMenu($0, from: $1) }

    init(host: SidebarView) { self.host = host }

    // MARK: Accessory slots

    func layoutFooter(_ slots: [(SidebarAccessorySlot, NSView)]) {
        guard let f = host?.footer.bounds else { return }
        // Account and cloud lead; status fills the remaining space. Help is
        // in the Help menu and the account menu, not here
        // (SIDEBAR-FOOTER-MINIMAL).
        let side = Metrics.sidebarRowHeight
        var x = Metrics.space4
        for (slot, view) in slots {
            let width: CGFloat = switch slot {
            case .account, .cloud: side
            case .status: max(0, f.width - x - Metrics.space4)
            }
            view.frame = NSRect(x: x, y: (f.height - side) / 2, width: width, height: side)
            x += width + Metrics.space2
        }
    }

    // MARK: Spaces dots

    // `sidebar.spacesPosition` (R109): the spaces dots sit in the footer row,
    // after the profile control (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 3: one
    // row, avatar leading), or in their own row under the titlebar row. Either
    // way the strip is centered on the sidebar (cx-5k3r, Lawrence 2026-10-08:
    // "center spaces in bottom"), clamped so it never covers the control.

    /// The pinned footer section shows items, so the dots go in its first
    /// row. Valid after `updateBands()`.
    var dotsShareBandRow: Bool { !footerItemRows.isEmpty }

    /// The footer section's item rows (tiles and chips), in its region.
    private var footerItemRows: [SidebarRegionRow] {
        (host?.footerRegion.layoutResult.rows ?? []).filter {
            switch $0.kind {
            case .tile, .chip: true
            default: false
            }
        }
    }

    /// The footer section's first row in the sidebar's coordinates: its frame
    /// across the row, and where its items end. Nil when it shows none.
    var bandFirstRow: (frame: NSRect, itemsMaxX: CGFloat)? {
        let items = footerItemRows
        guard let host, let first = items.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        let line = items.filter { abs($0.frame.minY - first.frame.minY) < 0.5 }
        let frame = host.convert(first.frame, from: host.footerRegion)
        let maxX = line.map { host.convert($0.frame, from: host.footerRegion).maxX }.max() ?? frame.maxX
        return (frame, maxX)
    }

    /// Puts the dots in their row at `top` (`height` > 0), after the footer
    /// band's items in its first row, or in the footer when the band is empty.
    func placeSpaces(top: CGFloat, height: CGFloat) {
        guard let host else { return }
        let bar = host.profileBar, footer = host.footer, bounds = host.bounds
        if host.spacesPosition == .top {
            if bar.superview !== host { host.addSubview(bar) }
            bar.leadingInset = nil
            bar.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            bar.centerX = bounds.midX
        } else if let row = bandFirstRow {
            if bar.superview !== host { host.addSubview(bar) }
            // The bar starts right after the control (the strip never covers
            // it; the slots carry the gap) and centers on the sidebar's middle.
            bar.leadingInset = 0
            bar.frame = NSRect(x: row.itemsMaxX, y: row.frame.minY, width: max(0, bounds.width - row.itemsMaxX), height: row.frame.height)
            bar.centerX = bounds.midX - row.itemsMaxX
        } else {
            if bar.superview !== footer { footer.addSubview(bar) }
            bar.leadingInset = nil
            bar.frame = NSRect(x: 0, y: 0, width: footer.bounds.width, height: footer.bounds.height)
            bar.centerX = footer.convert(NSPoint(x: bounds.midX, y: 0), from: host).x
        }
        bar.refresh()
    }

    // MARK: Profile menu

    // SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2: the sidebar's bottom-left is
    // one control, the current profile's avatar. A click (or
    // the `sidebar.profileMenu` action) opens the one profile menu the App
    // builds from registry actions (`profileMenuProvider`).

    /// The item that draws the profile control, in band order, with its
    /// view: the footer's account item by default.
    var profileControl: (id: LayoutItemID, view: SidebarItemRowView)? {
        for region in host?.bandRegions ?? [] {
            for row in region.layoutResult.rows {
                guard case .tile(let id, _) = row.kind, let view = region.itemView(id), view.showsAvatar, !view.isHidden else { continue }
                return (id, view)
            }
        }
        return nil
    }

    /// Opens the profile menu over `anchor`. Returns false when the App gave
    /// no menu. Without an anchor (a hidden sidebar) the menu opens at the pointer.
    @discardableResult
    func showProfileMenu(from anchor: NSView?) -> Bool {
        guard let menu = host?.profileMenuProvider?() else { return false }
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
