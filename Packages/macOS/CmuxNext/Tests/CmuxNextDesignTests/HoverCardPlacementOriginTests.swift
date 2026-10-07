import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// Hover card origins (screen coordinates, y up): below the anchor, above
/// it (a bottom tab strip, R109), or beside it (sidebar rows).
@MainActor @Suite struct HoverCardPlacementOriginTests {
    @Test func eachPlacementSitsOnItsSideOfTheAnchor() {
        let anchor = CGRect(x: 100, y: 200, width: 80, height: 24)
        let size = CGSize(width: 240, height: 120)
        let gap = Metrics.space2
        #expect(HoverCardPanel.origin(for: .below, anchor: anchor, size: size) == CGPoint(x: 100, y: 200 - gap - 120))
        #expect(HoverCardPanel.origin(for: .above, anchor: anchor, size: size) == CGPoint(x: 100, y: 224 + gap))
        #expect(HoverCardPanel.origin(for: .beside, anchor: anchor, size: size) == CGPoint(x: 180 + gap, y: 224 - 120))
    }
}
