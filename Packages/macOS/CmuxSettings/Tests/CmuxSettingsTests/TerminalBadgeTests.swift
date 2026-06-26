import Foundation
import Testing
@testable import CmuxSettings

/// Behavior tests for the pure terminal-badge helpers backing the
/// per-workspace/per-tab overlay: template-token substitution, numeric
/// clamping, and the position key's stored representation.
@Suite("TerminalBadge template resolution")
struct TerminalBadgeTemplateTests {
    @Test func substitutesWorkspaceAndTabTokens() {
        #expect(
            TerminalBadge.resolveText(template: "{workspace} · {tab}", workspace: "cmux", tab: "shell")
                == "cmux · shell"
        )
    }

    @Test func passesLiteralTextThrough() {
        #expect(
            TerminalBadge.resolveText(template: "session", workspace: "W", tab: "T") == "session"
        )
    }

    @Test func replacesEveryTokenOccurrence() {
        #expect(
            TerminalBadge.resolveText(template: "{tab}/{tab}", workspace: "W", tab: "x") == "x/x"
        )
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(
            TerminalBadge.resolveText(template: "  {tab}  ", workspace: "", tab: "shell") == "shell"
        )
    }

    @Test func emptyTokensCanResolveToEmpty() {
        #expect(TerminalBadge.resolveText(template: "{workspace}{tab}", workspace: "", tab: "") == "")
    }

    @Test func defaultTemplateUsesBothTokens() {
        let resolved = TerminalBadge.resolveText(
            template: TerminalBadge.defaultTemplate,
            workspace: "Repo",
            tab: "agent"
        )
        #expect(resolved.contains("Repo"))
        #expect(resolved.contains("agent"))
    }
}

@Suite("TerminalBadge clamping")
struct TerminalBadgeClampTests {
    @Test func clampsOpacityIntoRange() {
        #expect(TerminalBadge.clampOpacity(-1) == TerminalBadge.minOpacity)
        #expect(TerminalBadge.clampOpacity(2) == TerminalBadge.maxOpacity)
        #expect(TerminalBadge.clampOpacity(0.5) == 0.5)
    }

    @Test func clampsNonFiniteOpacityToDefault() {
        #expect(TerminalBadge.clampOpacity(.nan) == TerminalBadge.defaultOpacity)
        #expect(TerminalBadge.clampOpacity(.infinity) == TerminalBadge.defaultOpacity)
    }

    @Test func clampsFontSizeIntoRange() {
        #expect(TerminalBadge.clampFontSize(0) == TerminalBadge.minFontSize)
        #expect(TerminalBadge.clampFontSize(10_000) == TerminalBadge.maxFontSize)
        #expect(TerminalBadge.clampFontSize(20) == 20)
    }

    @Test func clampsNonFiniteFontSizeToDefault() {
        #expect(TerminalBadge.clampFontSize(.nan) == TerminalBadge.defaultFontSize)
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
        #expect(terminal.badgeTemplate.defaultValue == TerminalBadge.defaultTemplate)
        #expect(terminal.badgeOpacity.defaultValue == TerminalBadge.defaultOpacity)
        #expect(terminal.badgeFontSize.defaultValue == TerminalBadge.defaultFontSize)
        #expect(terminal.badgeColorHex.defaultValue == TerminalBadge.defaultColorHex)
    }
}
