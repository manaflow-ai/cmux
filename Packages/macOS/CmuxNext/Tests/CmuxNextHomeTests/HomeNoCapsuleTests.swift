import AppKit
import Testing
@testable import CmuxNextHome

/// Leo's first-launch capture (op-next-look): capsule pills are banned in
/// cmux-next. The first-run rows are small-radius rects with a hairline,
/// never glass capsules. (The composer is MessagesLab's field, home-mac.md.)
@MainActor
@Suite struct HomeNoCapsuleTests {
    @Test func aFirstRunRowIsASmallRadiusRect() {
        let chip = HomeFirstRunRow(title: "Open a terminal", symbol: "apple.terminal")
        chip.frame = NSRect(origin: .zero, size: chip.intrinsicContentSize)
        chip.layoutSubtreeIfNeeded()
        #expect(!chip.subviews.contains { $0 is NSGlassEffectView })
        let radius = chip.surface.layer?.cornerRadius ?? 0
        #expect(radius > 0 && radius < chip.bounds.height / 2, "radius \(radius) on a \(chip.bounds.height) pt chip")
        #expect(chip.surface.layer?.borderWidth == 1)
    }
}
