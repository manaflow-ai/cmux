import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The profile strip uses colored dots for named spaces without an explicit icon.
@MainActor @Suite(.serialized) struct ProfileBarDotsTests {
    @Test func aNamedSpaceWithoutAnIconDrawsACompactDot() throws {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profiles = [
            SidebarProfile(id: ProfileKey("space-delta"), name: "Delta", color: .red),
            SidebarProfile(id: ProfileKey("space-other"), name: "Other", color: .blue),
        ]
        model.activeProfileID = model.profiles[1].id
        let view = ProfileBarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        view.layoutSubtreeIfNeeded()
        view.refresh()

        let rect = view.slotRects()[0]
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 28,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        view.marks.cacheDisplay(in: view.marks.bounds, to: rep)

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = Metrics.roomDotDiameter / 2 + 1
        var pixelsOutsideDot = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard abs(CGFloat(x) + 0.5 - center.x) <= radius,
                      abs(CGFloat(y) + 0.5 - center.y) <= radius else { continue }
                guard (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 else { continue }
                let distance = hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y)
                if distance > radius { pixelsOutsideDot += 1 }
            }
        }
        #expect(pixelsOutsideDot == 0, "the named space drew (pixelsOutsideDot) pixels outside its dot")
    }
}
