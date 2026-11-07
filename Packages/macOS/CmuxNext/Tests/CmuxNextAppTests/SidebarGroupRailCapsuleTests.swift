import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19775: "roundness of left bar needs to be better, like rounded on both top and bottom". The left
/// bar beside a group's member rows (`GroupLineView`, the group rail) is one capsule: its real layer, drawn into a
/// bitmap, has the same corner coverage at the top and the bottom, and on the left and the right, and its ink
/// reaches its own frame's ends (the caps are not clipped), at every density, text size and look, light and dark.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupRailCapsuleTests {
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
    func theLeftBarIsOneCapsule(_ c: Case) throws {
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
                // Rounded at every corner, the same amount.
                let corners = [a(0, 0), a(w - 1, 0), a(0, h - 1), a(w - 1, h - 1)]
                #expect(corners.allSatisfy { $0 < body / 3 }, "\(c): a square corner, alpha \(corners) against the body's \(body)")
                // The caps reach the frame's top and bottom: neither end is clipped short or cut off.
                #expect(a(w / 2, 0) >= body / 2 && a(w / 2, h - 1) >= body / 2,
                        "\(c): an end cap is clipped: top \(a(w / 2, 0)), bottom \(a(w / 2, h - 1)), body \(body)")
                // Mirror-symmetric top to bottom and left to right (a few anti-aliasing levels apart at most).
                var vertical = 0, horizontal = 0
                for y in 0..<h {
                    for x in 0..<w {
                        if abs(a(x, y) - a(x, h - 1 - y)) > 48 { vertical += 1 }
                        if abs(a(x, y) - a(w - 1 - x, y)) > 48 { horizontal += 1 }
                    }
                }
                #expect(vertical == 0, "\(c): the top and bottom ends differ in \(vertical) of \(w * h) pixels")
                #expect(horizontal == 0, "\(c): the left and right edges differ in \(horizontal) of \(w * h) pixels")
            }
        }
    }
}
