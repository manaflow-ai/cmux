import Testing
import Foundation
import CoreGraphics

@testable import CmuxSettingsUI

@Suite struct SettingsScrollSpyTests {
    // Offsets are each section top's minY in the scroll space: ~0 at the top,
    // negative once scrolled above the viewport top.

    @Test func picksTopmostSectionWhenNothingHasReachedTheLine() {
        // Viewport sitting above the first section: every top is below the line.
        let offsets: [SettingsSectionID: CGFloat] = [.account: 120, .app: 500, .terminal: 900]
        #expect(SettingsScrollSpy.activeSection(offsets: offsets, activationLine: 96) == .account)
    }

    @Test func picksSectionNearestLineFromAbove() {
        // account scrolled just above the line, app just under it.
        let offsets: [SettingsSectionID: CGFloat] = [.account: -50, .app: 40, .terminal: 600]
        #expect(SettingsScrollSpy.activeSection(offsets: offsets, activationLine: 96) == .app)
    }

    @Test func picksLastSectionScrolledPast() {
        let offsets: [SettingsSectionID: CGFloat] = [
            .account: -300, .app: -120, .terminal: -10, .textBox: 400,
        ]
        #expect(SettingsScrollSpy.activeSection(offsets: offsets, activationLine: 96) == .terminal)
    }

    @Test func emptyOffsetsReturnNil() {
        #expect(SettingsScrollSpy.activeSection(offsets: [:], activationLine: 96) == nil)
    }
}
