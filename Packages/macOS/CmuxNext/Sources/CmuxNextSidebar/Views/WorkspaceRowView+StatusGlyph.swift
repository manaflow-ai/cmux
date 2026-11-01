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

    static func machineMarkImage(_ mark: SidebarMachineMark, side: CGFloat) -> NSImage {
        if let emoji = mark.emoji { return SidebarItemRowView.emojiImage(emoji, side: side) }
        return mark.symbol.map { NSImage.icon(symbol: $0, size: side) } ?? NSImage.icon(mark.kindIcon, size: side)
    }
}
