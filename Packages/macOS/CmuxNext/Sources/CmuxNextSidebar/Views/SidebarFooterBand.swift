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
        // The Search button holds the row's right end (Lawrence 2026-10-27): status stops before it.
        let trailing = host?.design.sidebarSections.showSearchButton == true ? Self.searchButtonSide + Metrics.space2 : 0
        for (slot, view) in slots {
            let width: CGFloat = switch slot {
            case .account, .cloud: side
            case .status: max(0, f.width - x - Metrics.space4 - trailing)
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

    /// The footer section's first row in the sidebar's coordinates: its leading
    /// item's frame, and where its items end. Nil when it shows none.
    var bandFirstRow: (frame: NSRect, itemsMaxX: CGFloat)? {
        let items = footerItemRows
        // The row's leading item (the profile avatar): the Search button mirrors its inset.
        guard let host, let first = items.min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) else { return nil }
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
        // The Search button sits at the row's right end and the update button left of it: the strip ends before them.
        let searchMinX = placeSearch()
        let trailing = placeUpdateAvailable(before: searchMinX, after: bandFirstRow?.itemsMaxX ?? 0) ?? searchMinX
        if host.spacesPosition == .top {
            if bar.superview !== host { host.addSubview(bar) }
            bar.leadingInset = nil
            bar.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            bar.centerX = bounds.midX
        } else if let row = bandFirstRow {
            if bar.superview !== host { host.addSubview(bar) }
            // The bar runs from right after the control to the Search button (the
            // strip never covers either; the slots carry the gap) and centers on
            // the sidebar's middle.
            let lead = row.itemsMaxX, end = trailing ?? bounds.width
            bar.leadingInset = 0
            bar.frame = NSRect(x: lead, y: row.frame.minY, width: max(0, end - lead), height: row.frame.height)
            bar.centerX = bounds.midX - lead
        } else {
            if bar.superview !== footer { footer.addSubview(bar) }
            // The strip ends before the Search and update buttons at the row's right end.
            let end = trailing.map { footer.convert(NSPoint(x: $0, y: 0), from: host).x } ?? footer.bounds.width
            bar.leadingInset = nil
            bar.frame = NSRect(x: 0, y: 0, width: max(0, end), height: footer.bounds.height)
            bar.centerX = footer.convert(NSPoint(x: bounds.midX, y: 0), from: host).x
        }
        bar.refresh()
    }

    // MARK: Search button

    /// The Search button's side: the footer row's height (one slim row, no extra padding; it was a
    /// 28 pt HIG minimum that added 2 pt under the line). Lawrence 2026-10-27: footer too tall.
    static var searchButtonSide: CGFloat { Metrics.sidebarRowHeight }

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

    /// Places the Search button (plans/cmux-next/sidebar-search.md) at the footer row's right
    /// end (Lawrence 2026-10-27 message 14242: "move the bottom-left search thing to the right
    /// side"), its inset mirroring the profile avatar's at the left, on the avatar's line; at
    /// the footer's right end when the band shows none. It never covers the band's first-row
    /// items. Returns its minX in the sidebar's coordinates, or nil when
    /// `sidebar.showSearchButton` or `sidebar.noFade` hides it.
    @discardableResult
    func placeSearch() -> CGFloat? {
        guard let host else { return nil }
        let button = host.searchButton
        // `sidebar.noFade` hides the whole footer bar, the Search button with it.
        guard host.design.sidebarSections.showSearchButton, !host.design.sidebarSections.noFade else {
            button.isHidden = true
            return nil
        }
        button.isHidden = false
        let side = Self.searchButtonSide
        let x: CGFloat, midY: CGFloat
        if let row = bandFirstRow {
            // The avatar's left inset, mirrored at the right, the lens on its center line.
            let rightEnd = host.bounds.maxX - row.frame.minX - side
            (x, midY) = (max(row.itemsMaxX, rightEnd), row.frame.midY + searchLensDrop)
        } else {
            let footer = host.footer.frame
            // An empty band: the footer row, or on the bottom inset when the footer has no height.
            (x, midY) = (host.bounds.maxX - Metrics.space4 - side, footer.height > 0 ? footer.midY
                : host.bounds.maxY - SidebarStyle.bottomInset - side / 2)
        }
        let scale = host.window?.backingScaleFactor ?? 2
        button.frame = NSRect(x: (x * scale).rounded() / scale, y: ((midY - side / 2) * scale).rounded() / scale, width: side, height: side)
        return button.frame.minX
    }

    // MARK: Update Available button

    /// Places the quiet Update Available button (`showUpdateAvailable`) on the footer line's trailing end,
    /// left of the Search button (`searchMinX`; at Search's own inset when Search is hidden), on its line
    /// (Leo 2026-10-28: "the update button, don't put at the top. Put on the bottom. The bottom has room").
    /// Returns its minX in the sidebar's coordinates, nil while it does not show. It never covers the line's
    /// leading controls (`after`, the avatar's maxX): with no room it steps out of the line (zero frame; the
    /// palette's Install Available Update still installs it), as it stepped out of the titlebar row before.
    @discardableResult
    func placeUpdateAvailable(before searchMinX: CGFloat?, after leadingMaxX: CGFloat) -> CGFloat? {
        guard let host else { return nil }
        let button = host.updateAvailableButton
        guard !button.isHidden else { return nil }
        let side = Self.searchButtonSide
        let midY: CGFloat, end: CGFloat
        if let row = bandFirstRow {
            midY = row.frame.midY
            end = searchMinX.map { $0 - Metrics.space1 } ?? host.bounds.maxX - row.frame.minX
        } else {
            let footer = host.footer.frame
            midY = footer.height > 0 ? footer.midY : host.bounds.maxY - SidebarStyle.bottomInset - side / 2
            end = searchMinX.map { $0 - Metrics.space1 } ?? host.bounds.maxX - Metrics.space4
        }
        let x = end - side
        guard x >= leadingMaxX + Metrics.space1 else {
            button.frame = .zero
            return nil
        }
        let scale = host.window?.backingScaleFactor ?? 2
        button.frame = NSRect(x: (x * scale).rounded() / scale, y: ((midY - side / 2) * scale).rounded() / scale, width: side, height: side)
        return button.frame.minX
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
