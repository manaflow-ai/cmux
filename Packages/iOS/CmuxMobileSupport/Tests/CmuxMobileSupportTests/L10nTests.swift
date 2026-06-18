import Testing
@testable import CmuxMobileSupport

@Suite struct L10nTests {
    // In a swift-test context the app catalog is absent, so lookups fall back
    // to the supplied default value; these assert the formatting contract on
    // that fallback path.
    @Test func terminalCountSingularUsesOneForm() {
        #expect(L10n.terminalCount(1) == "1 terminal")
    }

    @Test func terminalCountPluralFormatsCount() {
        #expect(L10n.terminalCount(3) == "3 terminals")
        #expect(L10n.terminalCount(0) == "0 terminals")
    }

    @Test func workspaceNameInterpolatesIndex() {
        #expect(L10n.workspaceName(index: 2) == "Workspace 2")
    }

    @Test func terminalNameInterpolatesIndex() {
        #expect(L10n.terminalName(index: 7) == "Terminal 7")
    }
}
