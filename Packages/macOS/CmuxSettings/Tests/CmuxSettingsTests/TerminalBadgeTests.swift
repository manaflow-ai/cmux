import Foundation
import Testing
@testable import CmuxSettings

/// Behavior tests for ``TerminalBadgeConfiguration`` backing the
/// per-workspace/per-tab overlay: template-token substitution, numeric
/// clamping on init, and the catalog defaults / position stored representation.
@Suite("TerminalBadgeConfiguration template resolution")
struct TerminalBadgeTemplateTests {
    @Test func substitutesWorkspaceAndTabTokens() {
        let config = TerminalBadgeConfiguration(template: "{workspace} · {tab}")
        #expect(config.resolvedText(workspace: "cmux", tab: "shell") == "cmux · shell")
    }

    @Test func passesLiteralTextThrough() {
        let config = TerminalBadgeConfiguration(template: "session")
        #expect(config.resolvedText(workspace: "W", tab: "T") == "session")
    }

    @Test func replacesEveryTokenOccurrence() {
        let config = TerminalBadgeConfiguration(template: "{tab}/{tab}")
        #expect(config.resolvedText(workspace: "W", tab: "x") == "x/x")
    }

    @Test func trimsSurroundingWhitespace() {
        let config = TerminalBadgeConfiguration(template: "  {tab}  ")
        #expect(config.resolvedText(workspace: "", tab: "shell") == "shell")
    }

    @Test func emptyTokensCanResolveToEmpty() {
        let config = TerminalBadgeConfiguration(template: "{workspace}{tab}")
        #expect(config.resolvedText(workspace: "", tab: "") == "")
    }

    @Test func defaultTemplateUsesBothTokens() {
        let resolved = TerminalBadgeConfiguration().resolvedText(workspace: "Repo", tab: "agent")
        #expect(resolved.contains("Repo"))
        #expect(resolved.contains("agent"))
    }
}

@Suite("TerminalBadgeConfiguration clamping")
struct TerminalBadgeClampTests {
    @Test func clampsOpacityIntoRange() {
        #expect(TerminalBadgeConfiguration(opacity: -1).opacity == TerminalBadgeConfiguration.opacityRange.lowerBound)
        #expect(TerminalBadgeConfiguration(opacity: 2).opacity == TerminalBadgeConfiguration.opacityRange.upperBound)
        #expect(TerminalBadgeConfiguration(opacity: 0.5).opacity == 0.5)
    }

    @Test func clampsNonFiniteOpacityToDefault() {
        #expect(TerminalBadgeConfiguration(opacity: .nan).opacity == TerminalBadgeConfiguration.defaultOpacity)
        #expect(TerminalBadgeConfiguration(opacity: .infinity).opacity == TerminalBadgeConfiguration.defaultOpacity)
    }

    @Test func clampsFontSizeIntoRange() {
        #expect(TerminalBadgeConfiguration(fontSize: 0).fontSize == TerminalBadgeConfiguration.fontSizeRange.lowerBound)
        #expect(TerminalBadgeConfiguration(fontSize: 10_000).fontSize == TerminalBadgeConfiguration.fontSizeRange.upperBound)
        #expect(TerminalBadgeConfiguration(fontSize: 20).fontSize == 20)
    }

    @Test func clampsNonFiniteFontSizeToDefault() {
        #expect(TerminalBadgeConfiguration(fontSize: .nan).fontSize == TerminalBadgeConfiguration.defaultFontSize)
    }
}

@Suite("TerminalBadge catalog keys")
struct TerminalBadgeCatalogTests {
    private func makeScratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cmux.tests.badge.\(UUID().uuidString)")!
    }

    @Test func positionDefaultsToTopTrailingAndRoundTrips() {
        let key = TerminalCatalogSection().badgePosition
        let defaults = makeScratchDefaults()
        #expect(key.value(in: defaults) == .topTrailing)

        key.set(.bottomLeading, in: defaults)
        #expect(key.value(in: defaults) == .bottomLeading)
    }

    @Test func badgeDefaultsMatchSharedConstants() {
        let terminal = TerminalCatalogSection()
        #expect(terminal.badgeEnabled.defaultValue == false)
        #expect(terminal.badgeTemplate.defaultValue == TerminalBadgeConfiguration.defaultTemplate)
        #expect(terminal.badgeOpacity.defaultValue == TerminalBadgeConfiguration.defaultOpacity)
        #expect(terminal.badgeFontSize.defaultValue == TerminalBadgeConfiguration.defaultFontSize)
        #expect(terminal.badgeColorHex.defaultValue == TerminalBadgeConfiguration.defaultColorHex)
    }
}
