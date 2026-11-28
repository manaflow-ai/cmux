import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The Home pane rendered offscreen, light and dark, with an agent's short Markdown and a
/// drag selection: the visual pin for engine moves. With HOME_RENDER_OUT set, the PNG is
/// written there (compare two revisions byte for byte); the test checks that rows drew.
@MainActor @Suite(.serialized) struct HomeRenderTests {
    static let agent = [
        "Plan: **ship the pin** after the `verify-clean` pass.",
        "Steps:\n- one *italic* step\n- a [link](https://cmux.com)\n- ~~old~~ new",
        "Select this sentence to check the highlight on the transcript.",
    ]

    private func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func render(dark: Bool) async throws -> CGImage {
        let theme = dark
            ? HomePalette.Theme(background: .gray255(30), foreground: .gray255(235), accent: .rgb255(10, 132, 255), failure: .rgb255(255, 69, 58))
            : HomePalette.Theme(background: .gray255(255), foreground: .gray255(20), accent: .rgb255(0, 122, 255), failure: .rgb255(255, 59, 48))
        Fixture.theme = FixtureTheme(active: .themed(theme), inactive: .themed(theme, active: false))
        Fixture.lightAppearance = !dark
        RowBitmaps.shared.removeAll()
        let (p, c) = Fixture2.projection()
        var items = [Fixture2.item(1, Fixture2.me, "Status of the MessagesLab pin?")]
        for (i, t) in Self.agent.enumerated() { items.append(Fixture2.item(Seq(i + 2), Fixture2.them, t)) }
        items.append(Fixture2.item(5, Fixture2.me, "Thanks, **looks good** (mine stays as typed)."))
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 5), typing: [], hasOlder: false)
        c.demo!.backgroundColor = Fixture.background
        c.host.layoutSubtreeIfNeeded(); c.demo!.layoutIfNeeded(); c.demo!.collection.layoutIfNeeded()
        let hit = try #require(c.demo!.lastTextRow(mine: false))
        let from = CGPoint(x: hit.body.minX + 16, y: hit.body.minY + 14), to = CGPoint(x: hit.body.maxX - 30, y: hit.body.maxY - 12)
        c.mouseDown(at: from, event(.leftMouseDown))
        c.mouseDragged(at: to, event(.leftMouseDragged))
        c.mouseUp(at: to, event(.leftMouseUp))
        #expect(!c.selection.selectedText.isEmpty, "the drag made a selection")
        // Row bitmaps draw asynchronously: let them land.
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(40))
            c.host.layoutSubtreeIfNeeded(); c.demo!.collection.layoutIfNeeded(); CATransaction.flush()
        }
        let b = c.host.bounds
        let ctx = try #require(CGContext(data: nil, width: Int(b.width * 2), height: Int(b.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(Fixture.background.cgColor); ctx.fill(b)
        c.host.below.root.render(in: ctx)
        c.host.selectionHost.root.render(in: ctx)
        return try #require(ctx.makeImage())
    }

    /// Distinct pixel values in a coarse sample: a blank render has one.
    private func distinctColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) {
                let o = y * image.bytesPerRow + x * 4
                seen.insert(UInt32(bytes[o]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]))
            }
        }
        return seen.count
    }

    @Test func lightAndDarkRender() async throws {
        let light = try await render(dark: false), dark = try await render(dark: true)
        #expect(distinctColors(light) > 8 && distinctColors(dark) > 8, "rows drew")
        guard let out = ProcessInfo.processInfo.environment["HOME_RENDER_OUT"] else { return }
        let ctx = try #require(CGContext(data: nil, width: light.width + dark.width, height: max(light.height, dark.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(light, in: CGRect(x: 0, y: 0, width: light.width, height: light.height))
        ctx.draw(dark, in: CGRect(x: light.width, y: 0, width: dark.width, height: dark.height))
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}
