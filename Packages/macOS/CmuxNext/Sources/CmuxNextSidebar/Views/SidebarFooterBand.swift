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
        let searchMaxX = placeSearch()
        if host.spacesPosition == .top {
            if bar.superview !== host { host.addSubview(bar) }
            bar.leadingInset = nil
            bar.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            bar.centerX = bounds.midX
        } else if let row = bandFirstRow {
            if bar.superview !== host { host.addSubview(bar) }
            // The bar starts right after the control and the Search button (the
            // strip never covers them; the slots carry the gap) and centers on
            // the sidebar's middle.
            let lead = max(row.itemsMaxX, searchMaxX ?? 0)
            bar.leadingInset = 0
            bar.frame = NSRect(x: lead, y: row.frame.minY, width: max(0, bounds.width - lead), height: row.frame.height)
            bar.centerX = bounds.midX - lead
        } else {
            if bar.superview !== footer { footer.addSubview(bar) }
            // The Search button holds the leading slot; the strip starts after it.
            let lead = searchMaxX.map { footer.convert(NSPoint(x: $0, y: 0), from: host).x } ?? 0
            bar.leadingInset = searchMaxX == nil ? nil : 0
            bar.frame = NSRect(x: lead, y: 0, width: max(0, footer.bounds.width - lead), height: footer.bounds.height)
            bar.centerX = footer.convert(NSPoint(x: bounds.midX, y: 0), from: host).x - lead
        }
        bar.refresh()
    }

    // MARK: Search button

    /// The smallest side of the Search button: the macOS minimum control size (HIG, 28 pt).
    static let searchButtonMinSide: CGFloat = 28
    /// The Search button's side: the minimum control size, or the row where that is taller.
    static var searchButtonSide: CGFloat { max(searchButtonMinSide, Metrics.sidebarRowHeight) }

    /// The pinned footer section's padding under its last row. The footer is one line, the
    /// account control and the Search button centered on it, whose taller control ends on
    /// `SidebarStyle.bottomInset` (Leo 2026-10-20: the line sat too high, the section's own
    /// padding stacked on the margin): no padding under a row as tall as the button, half the
    /// difference under a shorter one, which the button overhangs.
    func footerBottomPadding(rowHeight: CGFloat) -> CGFloat {
        guard host?.design.sidebarSections.showSearchButton == true else { return 0 }
        return max(0, (Self.searchButtonSide - rowHeight) / 2 + searchLensDrop)
    }

    /// How far the Search button sits under the avatar's center line: one device pixel. The eye
    /// centers the magnifying glass on its lens, which rides above the glyph's middle with the
    /// handle hanging below (half a point at 14 pt, measured in #23717's capture), so a button
    /// centered on the line read as floating high (Leo 2026-10-21: "move the magnifying glass a
    /// bit lower").
    var searchLensDrop: CGFloat { 1 / (host?.window?.backingScaleFactor ?? 2) }

    /// Places the Search button (plans/cmux-next/sidebar-search.md) right after the
    /// footer band's first-row items (the profile avatar), on their line, or
    /// leading in the footer when the band shows none. Returns its maxX in the
    /// sidebar's coordinates, or nil when `sidebar.showSearchButton` hides it.
    @discardableResult
    func placeSearch() -> CGFloat? {
        guard let host else { return nil }
        let button = host.searchButton
        guard host.design.sidebarSections.showSearchButton else {
            button.isHidden = true
            return nil
        }
        button.isHidden = false
        let side = Self.searchButtonSide
        let x: CGFloat, midY: CGFloat
        if let row = bandFirstRow {
            // Flush after the avatar's square, the lens on its center: the two controls' own
            // insets are the gap between them, as a toolbar's buttons (Leo 2026-10-21: "this
            // stupid space").
            (x, midY) = (row.itemsMaxX, row.frame.midY + searchLensDrop)
        } else {
            let footer = host.footer.frame
            // An empty band: the footer row, or on the bottom inset when the footer has no height.
            (x, midY) = (Metrics.space4, footer.height > 0 ? footer.midY
                : host.bounds.maxY - SidebarStyle.bottomInset - side / 2)
        }
        let scale = host.window?.backingScaleFactor ?? 2
        button.frame = NSRect(x: x, y: ((midY - side / 2) * scale).rounded() / scale, width: side, height: side)
        return button.frame.maxX
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
                // The profile control draws the avatar alone, as a tile or a chip.
                let id: LayoutItemID
                switch row.kind {
                case .tile(let tile, _), .chip(let tile, _): id = tile
                default: continue
                }
                guard let view = region.itemView(id), view.showsAvatar, !view.isHidden else { continue }
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
            // The control holds its selected fill while the menu is open
            // (popUp returns when the menu closes).
            let control = anchor as? SidebarItemRowView
            control?.showsMenu = true
            defer { control?.showsMenu = false }
            menu.popUp(positioning: nil, at: origin, in: anchor)
        }
    }
}
