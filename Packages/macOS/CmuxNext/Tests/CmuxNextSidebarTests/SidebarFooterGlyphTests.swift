import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-AND-SPACE-MENU (Lawrence 2026-10-06, footer screenshot:
/// "this looks bad"): icon-only items read at different sizes. Every
/// icon-only item now draws its glyph ink at one visual size, on one center
/// line, centered in its square. Since amendment 2 the default footer is
/// the profile control alone (its own drawn avatar, SidebarProfileControlTests);
/// this suite keeps the glyph rule for icon items a user puts in the footer
/// (an account without a profile, the Settings gear). The test draws each
/// item's glyph offscreen at its frame and measures the opaque pixels.
@MainActor @Suite(.serialized) struct SidebarFooterGlyphTests {
    private func sidebar() throws -> SidebarView {
        let model = SidebarModel()
        model.layout = try SidebarLayoutReducer.reduce(model.layout, .itemAdd(
            LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings), showsLabel: false),
            section: SidebarLayoutDocument.bottomSectionID, index: 1)).get()
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The ink box of `item`'s drawn glyph, in the sidebar's coordinates
    /// (top-left origin): the glyph image drawn into its frame on a
    /// quarter-point bitmap, alpha at least a quarter.
    private func ink(_ item: SidebarItemRowView, in view: SidebarView) throws -> CGRect {
        let image = try #require(item.glyphImage)
        let frame = item.glyphFrame
        let scale: CGFloat = 4
        let width = Int((frame.width * scale).rounded(.up)), height = Int((frame.height * scale).rounded(.up))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 64 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX, "the glyph draws")
        let local = CGRect(x: frame.minX + CGFloat(minX) / scale, y: frame.minY + CGFloat(minY) / scale,
                           width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return view.convert(item.convert(local, to: view.footerRegion), from: view.footerRegion)
    }

    @Test func theAvatarAndTheGearDrawAtOneSizeOnOneCenterLine() throws {
        let view = try sidebar()
        let account = try #require(view.footerRegion.itemView(LayoutItemID("itm_account")))
        let gear = try #require(view.footerRegion.itemView(LayoutItemID("itm_settings")))
        let a = try ink(account, in: view), g = try ink(gear, in: view)
        let accountBox = view.convert(account.frame, from: view.footerRegion)
        let gearBox = view.convert(gear.frame, from: view.footerRegion)
        let target = SidebarStyle.kindGlyphSize
        // One visual size: the avatar's circle spans the gear's teeth.
        #expect(abs(a.width - g.width) <= 1 && abs(a.height - g.height) <= 1, "avatar \(a.size) gear \(g.size)")
        #expect(abs(max(a.width, a.height) - target) <= 1, "avatar ink \(a.size), want \(target) pt")
        #expect(abs(max(g.width, g.height) - target) <= 1, "gear ink \(g.size), want \(target) pt")
        // One center line, each ink centered in its square.
        #expect(abs(a.midY - g.midY) <= 0.5, "center lines \(a.midY) \(g.midY)")
        #expect(abs(a.midX - accountBox.midX) <= 0.5 && abs(a.midY - accountBox.midY) <= 0.5, "avatar centered: \(a) in \(accountBox)")
        #expect(abs(g.midX - gearBox.midX) <= 0.5 && abs(g.midY - gearBox.midY) <= 0.5, "gear centered: \(g) in \(gearBox)")
        // An even gap: the space between the glyphs equals the margins
        // around them in their squares (the squares touch).
        let gap = g.minX - a.maxX
        let margins = (accountBox.maxX - a.maxX) + (g.minX - gearBox.minX)
        #expect(gap > 0 && abs(gap - margins) <= 1, "gap \(gap), margins \(margins)")
        // On the rows' glyph column, at the row inset.
        let column = SidebarStyle.horizontalInset * 2 + SidebarStyle.iconBox / 2
        #expect(abs(a.midX - column) <= 0.5, "avatar ink on the row glyph column: \(a.midX) vs \(column)")
    }
}
