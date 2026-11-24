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
        // An agent in a terminal draws its mark knocked out of a tile, in a slot that holds one (16 and up).
        if drawsTerminalTile(workspace, variant: variant), let tile = terminalTileMark(workspace, slot: side) { return tile }
        return registeredAgentMark(workspace, side: side)
            // A harness workspace with no registered mark draws its kind's symbol, in its stable colour.
            ?? (workspace.kind == .harness ? NSImage.icon(symbol: workspace.kind.symbol, size: side) : nil)
    }

    /// Whether the row's agent mark draws as the reverse-video tile: its agent runs in a terminal
    /// (`SidebarWorkspace.agentInTerminal`) and the mark's slot holds a tile (`TerminalMarkTile.holds`).
    static func drawsTerminalTile(_ workspace: SidebarWorkspace, variant: SidebarAgentMarkVariant) -> Bool {
        let side = variant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
        return variant != .off && workspace.agentInTerminal && TerminalMarkTile.holds(slot: side)
    }

    /// What a row's terminal tile draws: its mark and slot. Equal keys draw the same tile, so a row configured
    /// again keeps the tile it has (`agentMarkTile`) and the bitmap AppKit drew for it.
    static func terminalTileKey(_ workspace: SidebarWorkspace, slot: CGFloat) -> String {
        switch workspace.agentIcon {
        case .image(let favicon)?: "i|\(ObjectIdentifier(favicon.image))|\(slot)"
        case .symbol(let name)?: "s|\(name)|\(slot)"
        case nil: "b|\(workspace.agentBrand ?? "")|\(workspace.kind == .harness)|\(slot)"
        }
    }

    /// The registered mark (or the harness symbol) at the tile's mark size, knocked out of a `slot` tile.
    static func terminalTileMark(_ workspace: SidebarWorkspace, slot: CGFloat) -> NSImage? {
        let markSide = TerminalMarkTile.markSide(slot: slot)
        guard let mark = registeredAgentMark(workspace, side: markSide)
            ?? (workspace.kind == .harness ? NSImage.icon(symbol: workspace.kind.symbol, size: markSide) : nil) else { return nil }
        return terminalTile(mark, slot: slot)
    }

    /// The row's agent mark image: its terminal tile kept from the last configure when it draws the same one.
    func agentMarkImage(_ workspace: SidebarWorkspace, placeholder: Bool) -> NSImage? {
        let side = agentMarkVariant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
        guard !placeholder, Self.drawsTerminalTile(workspace, variant: agentMarkVariant) else {
            agentMarkTile = nil
            return Self.agentMarkImage(workspace, variant: agentMarkVariant, placeholder: placeholder)
        }
        let key = Self.terminalTileKey(workspace, slot: side)
        if let kept = agentMarkTile, kept.key == key { return kept.image }
        let image = Self.agentMarkImage(workspace, variant: agentMarkVariant, placeholder: placeholder)
        agentMarkTile = image.map { (key, $0) }
        return image
    }

    /// `mark` knocked out of a `slot` tile (`TerminalMarkTile`), as a template the row tints with its ink: the
    /// tile's alpha is the tile less the mark, so the row's fill shows through the mark, selected or not.
    /// AppKit draws it once per backing scale and keeps that bitmap.
    static func terminalTile(_ mark: NSImage, slot: CGFloat) -> NSImage {
        let tile = NSImage(size: NSSize(width: slot, height: slot), flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            let scale = max(1, abs(context.cgContext.userSpaceToDeviceSpaceTransform.a))
            let markSide = TerminalMarkTile.markSide(slot: slot)
            var markRect = NSRect(x: 0, y: 0, width: markSide, height: markSide)
            guard let markImage = mark.cgImage(forProposedRect: &markRect, context: context, hints: nil),
                  let image = TerminalMarkTile.image(mark: markImage, slot: slot, scale: scale, ink: CGColor(gray: 0, alpha: 1)) // colour-allow: a template's alpha mask; the row tints it with its ink
            else { return false }
            context.cgContext.draw(image, in: rect)
            return true
        }
        tile.isTemplate = true
        tile.accessibilityDescription = mark.accessibilityDescription
        return tile
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
