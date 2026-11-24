import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

@MainActor struct SpaceButtonSpacingTests {
    @Test func theChosenSpacingHoldsOnAnOpenOrScrollingStripAndResetRestoresDensity() throws {
        let key = try #require(MetricKey(rawValue: "spaceButtonSpacing"))
        let design = DesignSettings.shared
        let previous = design.overrides[key]
        defer { design.setOverride(key, previous) }
        design.setOverride(key, nil)
        let model = SidebarModel()
        model.profiles = (0..<10).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        model.activeProfileID = model.profiles[5].id
        let bar = ProfileBarView(model: model)
        bar.leadingInset = 0
        bar.frame = NSRect(x: 0, y: 0, width: 144, height: 28)
        let densityWidths = bar.slotRects().map(\.width)
        for spacing: CGFloat in [18, 40] {
            design.setOverride(key, spacing)
            let pitch = Metrics.scale(spacing)
            for width: CGFloat in [600, 144] {
                bar.frame.size.width = width
                let slots = bar.slotRects()
                #expect(abs(slots[2].midX - slots[1].midX - pitch) < 0.01)
                let active = slots[5]
                #expect(active.minX >= 0 && active.maxX <= slots[10].minX + 0.01)
                #expect(bar.interactionIndex(at: NSPoint(x: active.midX, y: active.midY)) == 5)
            }
        }
        design.setOverride(key, nil)
        #expect(bar.slotRects().map(\.width) == densityWidths)
    }
}
