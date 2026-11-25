import AppKit
import CmuxAgentBrands
import CmuxNextIcons
import CmuxNextDesign

extension WorkspaceRowView {
    /// The status mark's frame (the shared indicator, or the agent mark standing in for it) ending
    /// at `trailing`: as tall as the unread badge, centered on `centerY`, the line the badge and
    /// the row's other trailing marks share (a compact row's middle, a one-line row's and a
    /// two-line row's alike; an expanded row's title line), on the pixel grid. Leo 2026-10-14:
    /// a mark on the title's capitals sat above the badge ("why is it superscript?"), and a
    /// two-line row centers it on the whole row.
    func statusGlyphFrame(trailing: CGFloat, centerY: CGFloat) -> NSRect {
        let side = SidebarStyle.statusGlyphSize
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snapped(trailing - side), y: snapped(centerY - side / 2), width: side, height: side)
    }

    /// The status mark that draws in the leading icon slot (`sidebar.workspaceRow.statusPlacement` `leading`): the
    /// row badge, else the agent mark standing in for the status, else the status glyph, as `layoutColumnMark` picks
    /// them on the trailing column. Nil when the status trails or the row is idle (the slot shows its icon or nothing).
    var leadingStatusMark: NSView? {
        guard statusLeads else { return nil }
        if !rowBadge.isHidden { return rowBadge }
        if !agentMark.isHidden && agentMarkVariant == .replacesStatus { return agentMark }
        return activity.showsGlyph ? activity : nil
    }

    /// Places the leading status `mark` in the icon slot whose box starts at `leading`, centered in it (a dot, a
    /// spinner and a warning differ in ink width, so a centered mark does not shift as the state changes), on
    /// `centerY`, on the pixel grid. The workspace's icon hides while the mark shows; the title keeps its x.
    func layoutLeadingStatus(_ mark: NSView, leading: CGFloat, slot: CGFloat, centerY: CGFloat) {
        let size = mark === rowBadge ? CGSize(width: rowBadge.preferredWidth, height: rowBadge.cellSide)
            : CGSize(width: SidebarStyle.statusGlyphSize, height: SidebarStyle.statusGlyphSize)
        let scale = window?.backingScaleFactor ?? 1
        mark.frame = NSRect(x: SidebarStyle.pixelSnapped(leading + (slot - size.width) / 2, scale: scale),
                            y: SidebarStyle.pixelSnapped(centerY - size.height / 2, scale: scale), width: size.width, height: size.height)
    }

    /// The agent mark's image size: the status mark's when it stands in for the status, the
    /// indicator size when it sits beside the title, so its brand variant matches the box it fills.
    var agentMarkSize: CGFloat {
        agentMarkVariant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
    }
}

extension WorkspaceRowView {
    /// A custom harness's own icon at the agent mark's size: an image drawn as is, a symbol as a
    /// template tinted like the marks.
    func agentIconImage(_ icon: SidebarAgentIcon) -> NSImage? {
        Self.agentIconImage(icon, side: agentMarkSize)
    }

    static func agentIconImage(_ icon: SidebarAgentIcon, side: CGFloat) -> NSImage? {
        switch icon {
        case .image(let favicon):
            let image = NSImage(cgImage: favicon.image, size: NSSize(width: side, height: side))
            image.isTemplate = false
            return image
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.82, weight: .regular)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }
    }
}


extension WorkspaceRowView {
    static func agentMarkImage(_ workspace: SidebarWorkspace, variant: SidebarAgentMarkVariant, placeholder: Bool) -> NSImage? {
        guard variant != .off, !placeholder else { return nil }
        let side = variant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
        return registeredAgentMark(workspace, side: side)
            // A harness workspace with no registered mark draws its kind's symbol, in its stable colour.
            ?? (workspace.kind == .harness ? NSImage.icon(symbol: workspace.kind.symbol, size: side) : nil)
    }

    /// The workspace's own icon or its brand's mark, when one is registered.
    static func registeredAgentMark(_ workspace: SidebarWorkspace, side: CGFloat) -> NSImage? {
        workspace.agentIcon.flatMap { agentIconImage($0, side: side) }
            ?? workspace.agentBrand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
    }

    /// The tint of a harness workspace's fallback mark (its stable per-item colour, resolved in the
    /// row's theme scope when drawn); nil for a registered mark, which keeps its own tint.
    static func agentMarkFallbackColor(_ workspace: SidebarWorkspace, variant: SidebarAgentMarkVariant) -> GroupColor? {
        let side = variant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
        guard workspace.kind == .harness, registeredAgentMark(workspace, side: side) == nil else { return nil }
        return SidebarItemInfo.stableAgentColor(for: workspace.id.rawValue)
    }
}
