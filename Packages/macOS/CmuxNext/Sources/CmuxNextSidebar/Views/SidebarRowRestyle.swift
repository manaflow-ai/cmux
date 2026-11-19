import AppKit
import CmuxNextDesign
import QuartzCore

/// The row restyle's state on one row (`SidebarRowRestyle`): nothing is made or changed while the restyle is off.
struct SidebarRowRestyleState {
    /// The full-width band the restyle paints the row's hover and selection on, and the `bar` style's accent bar.
    var band: CALayer?, mark: CALayer?
    /// The band is a capsule (the `capsule` style's selected row).
    var capsule = false
    /// The restyle changed something on this row since it was last off (`SidebarRowRestyle.restore`).
    var touched = false
    /// A workspace row the arrow keys selected while its list holds the keyboard: its hover controls and its clipped
    /// name's tooltip show, as on hover.
    var keyboardFocused = false
    /// The tooltip `keyboardFocused` showed is up.
    var focusTipShown = false
    /// The title font the row's configure set, while the restyle draws `appliedTitleFont` instead.
    var baseTitleFont: NSFont?, appliedTitleFont: NSFont?
    /// The made controls take the capsule's ink.
    var tinted = false
}

extension SidebarRowView {
    /// `experiments.sidebarRowStyle`. The sidebar's one observer lays out and repaints every row on a change
    /// (`SidebarView+Observation`, `SidebarListView.restyleChanged`), so a row reads it plainly.
    var rowStyle: SidebarRowStyle { DesignSettings.shared.sidebarRowStyle }
}

/// Taste build 7 (`experiments.sidebarRowStyle`, ``SidebarRowStyle``, off by default): every row's hover and selection
/// on one full-width band whatever its indent (only the content indents), group headers semibold with one leading
/// chevron, pin and close on hover and keyboard focus, a clipped title's tooltip on hover and keyboard focus, and the
/// selected row as a capsule, a leading bar or a soft fill. Off, nothing here draws or changes anything.
/// The restyle's values live here, and nowhere else.
@MainActor enum SidebarRowRestyle {
    /// The `bar` style's accent bar: its width (rounded ends) ...
    static let barWidth: CGFloat = 3
    /// ... and how far it stops short of the band's top and bottom, as a share of the row's height.
    static let barInsetShare: CGFloat = 0.25
    /// The `bar` style's selected row: a very faint share of the selection fill under its bar.
    static let barSelectionShare: CGFloat = 0.3
    /// The `soft` style's selected row: this share of the selection fill, quieter than today's.
    static let softSelectionShare: CGFloat = 0.55
    /// The ink of a capsule's second line and controls: the capsule's ink at this share.
    static let capsuleDetailShare: CGFloat = 0.75
    /// A group header's name, and the `bar` style's selected title: the emphasis weight at the title's size.
    static var emphasizedTitleFont: NSFont { SidebarStyle.titleFont(weight: TypeScale.emphasis) }
    /// One indent step: one icon column (a header's leading chevron), so a member's title starts under its header's
    /// and a nested header's chevron under its parent's members' titles.
    static var memberIndent: CGFloat {
        let columns = SidebarStyle.columns(rowWidth: 0)
        return columns.text - columns.lead
    }

    // MARK: Band

    /// Paints `color` on the row's band (inside `updateLayer`'s theme scope). False with the restyle off, after taking
    /// down whatever it left: the row paints its own layer as before.
    static func paint(_ row: SidebarRowView, _ color: NSColor?) -> Bool {
        let style = row.rowStyle
        guard style.isOn, let layer = row.layer else {
            takeDown(row)
            return false
        }
        row.restyle.touched = true
        if layer.backgroundColor != nil { ChromeHover.paint(layer, nil, animated: false) }
        let look = selectionLook(row, color, style)
        let band = row.restyle.band ?? makeLayer(row, below: true)
        row.restyle.band = band
        row.restyle.capsule = look.capsule
        if look.mark != nil, row.restyle.mark == nil { row.restyle.mark = makeLayer(row, below: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.restyle.mark?.isHidden = look.mark == nil
        row.restyle.mark?.backgroundColor = look.mark?.cgColor
        CATransaction.commit()
        place(row)
        ChromeHover.paint(band, look.fill, animated: row.fadesNextFill, clearing: .hoverOut)
        if let ws = row as? WorkspaceRowView { ink(ws, look.ink) }
        return true
    }

    private struct Look {
        var fill: NSColor?
        var capsule = false
        var mark: NSColor?
        var ink: NSColor?
    }

    /// Only the selected workspace row differs by style; hover and every other state keep their fill on the band.
    private static func selectionLook(_ row: SidebarRowView, _ color: NSColor?, _ style: SidebarRowStyle) -> Look {
        guard let ws = row as? WorkspaceRowView, ws.isSelected, !ws.isDropTarget else { return Look(fill: color) }
        // A row filled with its own color keeps it; the bar still marks it.
        let colored = ws.rowColor?.style == .fill
        switch style {
        case .off: return Look(fill: color)
        case .capsule: return colored ? Look(fill: color) : Look(fill: Palette.accentFill, capsule: true, ink: Palette.onAccent)
        case .bar: return Look(fill: colored ? color : share(Palette.selectionFill, barSelectionShare), mark: Palette.accentFill)
        case .soft: return Look(fill: colored ? color : share(Palette.selectionFill, softSelectionShare))
        }
    }

    private static func share(_ color: NSColor, _ share: CGFloat) -> NSColor? {
        share <= 0 ? nil : color.withAlphaComponent(color.alphaComponent * share)
    }

    private static func makeLayer(_ row: SidebarRowView, below: Bool) -> CALayer {
        let layer = CALayer()
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "cornerRadius": NSNull(),
                         "backgroundColor": NSNull(), "hidden": NSNull()]
        layer.cornerCurve = Metrics.tabCornerCurve
        if below {
            row.layer?.insertSublayer(layer, at: 0)
        } else if let band = row.restyle.band {
            row.layer?.insertSublayer(layer, above: band)
        } else {
            row.layer?.insertSublayer(layer, at: 0)
        }
        return layer
    }

    /// The band: from the list's leading inset to the row's end, whatever the row's indent, so every row's hover and
    /// selection span one width; the row's content keeps its indent. Constant per row (its own frame and the list's inset).
    static func bandRect(_ row: SidebarRowView) -> CGRect {
        let b = row.layoutBounds
        guard let list = row.superview as? SidebarListView else { return b }
        let lead = list.inset - row.frame.minX
        return CGRect(x: lead, y: b.minY, width: max(0, b.width - lead), height: b.height)
    }

    private static func place(_ row: SidebarRowView) {
        guard let band = row.restyle.band else { return }
        let rect = bandRect(row)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = rect
        band.cornerRadius = row.restyle.capsule ? rect.height / 2 : row.fillCornerRadius
        if let mark = row.restyle.mark {
            let inset = (rect.height * barInsetShare).rounded()
            mark.frame = CGRect(x: rect.minX, y: rect.minY + inset, width: barWidth, height: max(0, rect.height - 2 * inset))
            mark.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
    }

    /// The capsule's ink on the title, its second lines and its made controls; nil gives them back their own.
    private static func ink(_ ws: WorkspaceRowView, _ ink: NSColor?) {
        if let ink {
            ws.title.textColor = ink
            let detail = ink.withAlphaComponent(capsuleDetailShare)
            [ws.subtitle, ws.timeLabel, ws.metaLabel].forEach { $0.setColor(detail) }
        }
        guard ink != nil || ws.restyle.tinted else { return }
        ws.restyle.tinted = ink != nil
        let control = ink?.withAlphaComponent(capsuleDetailShare)
        ws.closeSlot.made?.tintOverride = control
        ws.pinSlot.made?.tintOverride = control
        ws.moreSlot.made?.tintOverride = control
    }

    private static func takeDown(_ row: SidebarRowView) {
        guard row.restyle.band != nil || row.restyle.mark != nil else { return }
        row.restyle.band?.removeFromSuperlayer()
        row.restyle.mark?.removeFromSuperlayer()
        (row.restyle.band, row.restyle.mark, row.restyle.capsule) = (nil, nil, false)
    }

    // MARK: Layout

    /// The start of every row's `layout()`: the band's geometry, and on a workspace row its keyboard focus and title
    /// weight (before the row measures its title). Off, it undoes what the restyle changed, once.
    static func layout(_ row: SidebarRowView) {
        let style = row.rowStyle
        guard style.isOn else { return restore(row) }
        row.restyle.touched = true
        place(row)
        guard let ws = row as? WorkspaceRowView else { return }
        ws.restyle.keyboardFocused = keyboardFocus(ws)
        let want = style == .bar && ws.isSelected ? emphasizedTitleFont : SidebarStyle.titleFont
        if ws.title.font != ws.restyle.appliedTitleFont { ws.restyle.baseTitleFont = ws.title.font }
        if ws.title.font != want { ws.title.font = want }
        ws.restyle.appliedTitleFont = want
    }

    private static func restore(_ row: SidebarRowView) {
        guard row.restyle.touched else { return }
        row.restyle.touched = false
        takeDown(row)
        guard let ws = row as? WorkspaceRowView else { return }
        ws.restyle.keyboardFocused = false
        if let base = ws.restyle.baseTitleFont, ws.title.font == ws.restyle.appliedTitleFont { ws.title.font = base }
        (ws.restyle.baseTitleFont, ws.restyle.appliedTitleFont) = (nil, nil)
        if let pin = ws.pinSlot.made {
            pin.icon = .statePinned
            pin.label = Strings.unpinWorkspace
        }
        ink(ws, nil)
        if ws.restyle.focusTipShown {
            ws.restyle.focusTipShown = false
            TooltipPresenter.shared.hideFocused(ws)
        }
    }

    /// A recycled row starts with no keyboard focus and no focus tooltip; its band repaints with its next content.
    static func reuse(_ row: SidebarRowView) {
        row.restyle.keyboardFocused = false
        if row.restyle.focusTipShown {
            row.restyle.focusTipShown = false
            TooltipPresenter.shared.hideFocused(row)
        }
    }

    // MARK: Keyboard focus

    /// The selected row of the list whose arrow keys selected it, while that list holds the keyboard of the key window.
    private static func keyboardFocus(_ ws: WorkspaceRowView) -> Bool {
        guard ws.isSelected, let list = ws.superview as? SidebarListView, list.restyleKeyboard,
              let window = list.window, window.isKeyWindow, window.firstResponder === list else { return false }
        return true
    }

    /// The list took the keyboard, or an arrow key moved its selection: its selected row reads as keyboard-focused.
    static func noteKey(in list: SidebarListView) {
        guard DesignSettings.shared.sidebarRowStyle.isOn else { return }
        list.restyleKeyboard = true
        relayoutSelected(in: list)
    }

    /// A click in the list: its selection is the pointer's again.
    static func noteMouse(in list: SidebarListView) {
        guard list.restyleKeyboard else { return }
        list.restyleKeyboard = false
        relayoutSelected(in: list)
    }

    /// The list let go of the keyboard: its rows' focus and focus tooltip go.
    static func focusLeft(_ list: SidebarListView) {
        guard DesignSettings.shared.sidebarRowStyle.isOn else { return }
        relayoutSelected(in: list)
    }

    private static func relayoutSelected(in list: SidebarListView) {
        for case let row as WorkspaceRowView in list.rowViews.values where row.isSelected || row.restyle.keyboardFocused {
            row.needsLayout = true
        }
    }

    /// After the row's tooltip text is set (`updateCalmTitleTip`): the keyboard focus shows it, a blur takes it away.
    static func focusTip(_ ws: WorkspaceRowView) {
        let wants = ws.restyle.keyboardFocused && ws.themedToolTip != nil
        guard wants != ws.restyle.focusTipShown else { return }
        ws.restyle.focusTipShown = wants
        // Called from the row's own layout: the list has set the row's frame, so the tooltip reads where it is now.
        if wants { TooltipPresenter.shared.showFocused(ws) } else { TooltipPresenter.shared.hideFocused(ws) }
    }

    // MARK: Pin on hover

    /// The restyle's pin: on hover and keyboard focus every workspace row the App can pin shows it, in the shared
    /// trailing column's next slot left of its close (or its ⋮), over the title's faded end, so nothing moves. It
    /// toggles the row's pin through the row's own action (`onPin`, the model's `workspacePin`); its glyph and label
    /// say what a press does. Returns where it starts, nil when it does not show.
    static func layoutPin(_ ws: WorkspaceRowView, rowWidth: CGFloat, control: CGFloat, fades: Bool) -> CGFloat? {
        let pinned = ws.isPinned?()
        let shown = ws.revealsHoverControls && !ws.isPlaceholderRow && !ws.renaming && ws.onPin != nil && pinned != nil
        ws.setHoverShown(ws.pinSlot, shown, fades: fades)
        if let button = ws.pinSlot.made {
            button.icon = pinned == true ? .statePinned : .actionPin
            button.label = pinned == true ? Strings.unpinWorkspace : Strings.pinWorkspace
        }
        guard shown else { return nil }
        // The close shows on a closable, unpinned row; the ⋮ wherever the row has a menu (the layout's own rule).
        let showsClose = !ws.isShowingPlaceholder && ws.isClosable && pinned != true
        let anchors = [showsClose ? ws.closeSlot.frame : nil, ws.onMore != nil ? ws.moreSlot.frame : nil].compactMap { $0 }
        let leftmost = anchors.min { $0.minX < $1.minX }
        let cy = ws.closeSlot.frame.midY
        if SidebarTunables.rowCloseSpot.value.atEnd {
            let center = SidebarStyle.trailingColumnCenterX(rowWidth: rowWidth)
            let slot = leftmost.map { Int(round((center - $0.midX) / SidebarStyle.trailingSlotPitch)) + 1 } ?? 0
            ws.pinSlot.frame = ws.trailingActionFrame(rowWidth: rowWidth, cy: cy, control: control, minimumSlot: slot)
        } else {
            ws.pinSlot.frame = leftmost?.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0) ?? ws.closeSlot.frame
        }
        return ws.pinSlot.frame.minX
    }

    // MARK: Group header

    /// How far a group header's icon and name move right for its leading chevron: one icon column under the restyle.
    static func headerLeadShift(_ header: GroupHeaderRowView) -> CGFloat { header.rowStyle.isOn ? memberIndent : 0 }

    /// How many slots the header's + and ⋮ move toward the trailing column, which the chevron no longer takes.
    static func headerSlotShift(_ header: GroupHeaderRowView) -> Int { header.rowStyle.isOn ? 1 : 0 }

    /// The header's one chevron: off, on the trailing column as before; on, leading, centered on the icon column before
    /// the (shifted) icon and name.
    static func headerChevronFrame(_ header: GroupHeaderRowView, columns: SidebarColumns, height: CGFloat, side: CGFloat) -> CGRect {
        guard header.rowStyle.isOn else {
            return SidebarStyle.trailingColumnFrame(rowWidth: columns.rowWidth, centerY: height / 2, side: side)
        }
        let center = SidebarStyle.iconColumnCenterX(leading: columns.lead - memberIndent)
        return CGRect(x: center - side / 2, y: (height - side) / 2, width: side, height: side)
    }

    /// The trailing slot the header keeps at rest: the chevron's off; the trailing column (its spinner's) on.
    static func headerRestSlot(_ header: GroupHeaderRowView, chevronFrame: CGRect) -> CGRect {
        guard header.rowStyle.isOn else { return chevronFrame }
        let b = header.layoutBounds
        return SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.height / 2, side: min(b.height, SidebarStyle.trailingSlotSide))
    }
}
