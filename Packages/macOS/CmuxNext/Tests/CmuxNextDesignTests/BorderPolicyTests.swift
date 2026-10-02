import AppKit
import Testing
@testable import CmuxNextDesign

/// Dogfood (2026-10-02): "make it possible to configure so there are no
/// borders at all anywhere in app." One switch, `appearance.borders`.
@Suite struct BorderPolicyTests {
    @Test func defaultKeepsEveryLine() {
        let policy = Borders(mode: .default)
        #expect(policy.drawsLines)
        #expect(policy.width(1) == 1)
        #expect(policy.color(.red) == .red)
    }

    @Test func noneRemovesEveryLine() {
        let policy = Borders(mode: .none)
        #expect(!policy.drawsLines)
        #expect(policy.width(1) == 0)
        #expect(policy.width(3) == 0)
        #expect(policy.color(.red).alphaComponent == 0, "separator colors resolve to clear, so lines keep their space")
    }

    @MainActor @Test func theLiveSwitchFollowsTheSettingAndTheTunable() {
        let saved = DesignSettings.shared.borders
        defer { DesignSettings.shared.borders = saved }
        DesignSettings.shared.borders = .none
        #expect(!Borders.drawsLines)
        #expect(Borders.width(2) == 0)
        #expect(Metrics.paneBorder == .none, "the pane border follows the switch")
        #expect(Palette.separator.alphaComponent == 0)
        DesignSettings.shared.borders = .default
        #expect(Borders.drawsLines)
    }
}
