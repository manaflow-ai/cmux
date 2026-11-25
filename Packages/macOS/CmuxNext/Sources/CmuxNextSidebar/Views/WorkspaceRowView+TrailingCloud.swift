import AppKit
import CmuxNextDesign
import CmuxNextIcons

extension WorkspaceRowView {
    /// The trailing cloud mark's side: the indicator box grown until the cloud's ink reads as large as the bell-slash
    /// beside it, by the rule every leading glyph fits by (`SidebarOpticalGlyph.fittedExtent`: height, or width / 1.25
    /// for a wide glyph). Leo 2026-11-24: "dont have such a dinky cloud icon. increase it ... you need to make sure all
    /// our icons look the right size". The pack's cloud is wide and short (20 x 14.25 of 24), so in the indicator box
    /// it stood about 6 pt tall at Compact while the bell stood 8 pt. Measured once per size (`SidebarGlyphInk` caches).
    static var cloudMarkSide: CGFloat {
        let ind = SidebarStyle.indicatorSize
        let probe = max(CGFloat.iconFloor, ind)
        let ink = SidebarGlyphInk.shared
        guard let cloud = ink.box(of: NSImage.icon(.cloud, size: probe), glyph: "trailing.cloud"),
              let bell = ink.box(of: NSImage.icon(symbol: "bell.slash", size: probe), glyph: "trailing.bell.slash")
        else { return ind }
        let cloudExtent = SidebarOpticalGlyph.fittedExtent(cloud.size)
        guard cloudExtent > 0 else { return ind }
        let grow = max(1, SidebarOpticalGlyph.fittedExtent(bell.size) / cloudExtent)
        return (ind * grow * 2).rounded() / 2
    }
}
