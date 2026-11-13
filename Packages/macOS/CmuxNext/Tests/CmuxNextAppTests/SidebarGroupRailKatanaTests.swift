import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-08: "that top tip area, it looks like a knife. You know what? I'll just call it the katana. It's good. We
/// need to add it." The left bar beside a group's member rows (`GroupLineView`, the group rail), its real layer drawn
/// into a bitmap: at the top the katana (the left edge square up to the tip, the top-right corner cut away, the full
/// width a little lower), at the bottom the round cap (Lawrence msg 19775), and its ink reaching its own frame's ends,
/// at every density, text size and look, light and dark.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupRailKatanaTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var textSize: SidebarTextSize
        var connected: Bool
        var dark: Bool
        var testDescription: String {
            "\(density.rawValue) \(textSize.rawValue) \(connected ? "connected" : "line") \(dark ? "dark" : "light")"
        }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        SidebarTextSize.allCases.flatMap { textSize in
            [false, true].flatMap { connected in [false, true].map { Case(density: density, textSize: textSize, connected: connected, dark: $0) } }
        }
    }

    /// The bitmap's pixels per point: a 2 pt rail is 16 px wide, enough to see a 1 pt cap.
    static let scale: CGFloat = 8

    /// The alpha of `view`'s layer drawn alone at `scale`, row by row (the context's own row order).
    static func coverage(_ view: NSView) throws -> (width: Int, height: Int, alpha: [UInt8]) {
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        view.displayIfNeeded()
        CATransaction.flush()
        let layer = try #require(view.layer)
        let width = Int((layer.bounds.width * scale).rounded()), height = Int((layer.bounds.height * scale).rounded())
        try #require(width > 0 && height > 0, "the rail has no size: \(layer.bounds)")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let data = try #require(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let alpha = (0..<(width * height)).map { bytes[$0 * 4 + 3] }
        return (width, height, alpha)
    }

    @Test(arguments: cases)
    func theLeftBarHasTheKatanaOnTopAndARoundCapBelow(_ c: Case) throws {
        try SidebarGroupChromeShapeTests.withShape(c.connected) {
            try SidebarGroupRailAlignmentTests.with(c.density, .off, textSize: c.textSize) {
                let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
                defer { window.close() }
                window.appearance = NSAppearance(named: c.dark ? .darkAqua : .aqua)
                sidebar.layoutSubtreeIfNeeded()
                let list = sidebar.list
                let frame = try #require(list.groupLineViews.shown[SidebarGroupLineLayoutTests.group]?.frame, "\(c): no rail")
                let view = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first { $0.frame == frame })
                // Not cut by the list's edge or its scroll clip: the whole rail sits in the list's bounds.
                #expect(list.bounds.contains(frame), "\(c): the rail \(frame) leaves the list \(list.bounds)")
                let last = try #require(list.rowViews[.workspace(SidebarGroupLineLayoutTests.members[2])])
                #expect(frame.maxY == last.frame.maxY, "\(c): the rail ends at \(frame.maxY), its last member at \(last.frame.maxY)")

                let (w, h, alpha) = try Self.coverage(view)
                func a(_ x: Int, _ y: Int) -> Int { Int(alpha[y * w + x]) }
                let body = a(w / 2, h / 2)
                try #require(body > 64, "\(c): the rail's body is not drawn (alpha \(body))")
                // Two pixel rows (a quarter point) in from each end, past the edge row's anti-aliasing. Which bitmap end is
                // the rail's top depends on the context's row order, so each end is read for its shape; that the tip is the
                // header's end is `SidebarGroupLineShape.body`'s (the path's y 0, the flipped view's top; theRailsTopIsTheKatana).
                // The katana: the left edge runs square to the tip and the right is cut. The round cap: both sides rounded
                // off, its middle reaching the end.
                func isTip(_ row: Int) -> Bool { a(0, row) >= body / 2 && a(w - 1, row) < body / 3 }
                func isCap(_ row: Int) -> Bool { a(0, row) < body / 3 && a(w - 1, row) < body / 3 && a(w / 2, row) >= body / 2 }
                let ends = [(tip: 2, cap: h - 3), (tip: h - 3, cap: 2)]
                if !ends.contains(where: { isTip($0.tip) && isCap($0.cap) }) {
                    let dump = (Array(0..<min(h, 8)) + Array(max(0, h - 8)..<h)).map { r in
                        "\(r):" + (0..<w).map { String(format: "%02x", a($0, r)) }.joined(separator: " ")
                    }.joined(separator: " | ")
                    let shape = "w \(w) h \(h) body \(body) rows \(dump)"
                    #expect(shape == "a katana over a round cap", "\(c)")
                }
                // Below the tip's curve (`SidebarGroupLineShape.tipLength`) the rail is its full width again.
                let tip = Int((SidebarGroupLineShape.tipLength(width: frame.width) * Self.scale).rounded())
                #expect(a(w - 1, tip + 2) >= body / 2 && a(w - 1, h - 1 - tip - 2) >= body / 2, "\(c): the rail is not full width past its ends")
            }
        }
    }
}
