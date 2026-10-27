import AppKit
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
        let side = agentMarkSize
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
