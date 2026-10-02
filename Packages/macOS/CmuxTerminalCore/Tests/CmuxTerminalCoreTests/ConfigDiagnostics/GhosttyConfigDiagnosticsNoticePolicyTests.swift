import Testing
@testable import CmuxTerminalCore

@Suite struct GhosttyConfigDiagnosticTests {
    @Test func parsesFileAndLineFromGhosttyFormat() {
        let diagnostic = GhosttyConfigDiagnostic(
            message: "/Users/me/.config/ghostty/config:12:font-sise: unknown field"
        )

        #expect(diagnostic.filePath == "/Users/me/.config/ghostty/config")
        #expect(diagnostic.line == 12)
        #expect(!diagnostic.isFromCmuxInlineConfig)
    }

    @Test func pathContainingColonKeepsWholePath() {
        let diagnostic = GhosttyConfigDiagnostic(message: "/tmp/a:b/config:3:theme: theme \"X\" not found")

        #expect(diagnostic.filePath == "/tmp/a:b/config")
        #expect(diagnostic.line == 3)
    }

    @Test func messageWithoutFileLocationHasNoPath() {
        let diagnostic = GhosttyConfigDiagnostic(message: "cli:1: invalid value")

        #expect(diagnostic.filePath == nil)
        #expect(diagnostic.line == nil)
    }

    @Test func parsesKeyAfterFileLocation() {
        let diagnostic = GhosttyConfigDiagnostic(
            message: "/Users/me/.config/ghostty/config:4:sidebar-font-size: unknown field"
        )

        #expect(diagnostic.key == "sidebar-font-size")
        #expect(diagnostic.isForCmuxOwnedKey)
    }

    @Test(arguments: ["sidebar-font-size", "surface-tab-bar-font-size"])
    func parsesKeyWithoutFileLocation(key: String) {
        let diagnostic = GhosttyConfigDiagnostic(message: "  \(key): unknown field\n")

        #expect(diagnostic.key == key)
        #expect(diagnostic.isForCmuxOwnedKey)
        #expect(diagnostic.filePath == nil)
        #expect(diagnostic.line == nil)
    }

    @Test func keylessDiagnosticsHaveNoKey() {
        #expect(GhosttyConfigDiagnostic(message: "/u/config:4: invalid syntax: here").key == nil)
        #expect(GhosttyConfigDiagnostic(message: "invalid syntax: here").key == nil)
        #expect(GhosttyConfigDiagnostic(message: ": unknown field").key == nil)
        #expect(GhosttyConfigDiagnostic(message: "invalid syntax").key == nil)
    }

    @Test func recognizesCmuxInlineFragments() {
        let diagnostic = GhosttyConfigDiagnostic(
            message: "/__cmux_inline__/cmux-renderer-bg.conf:1:macos-background-from-layer: unknown field"
        )

        #expect(diagnostic.isFromCmuxInlineConfig)
    }
}

@Suite struct GhosttyConfigDiagnosticsNoticePolicyTests {
    private let unknownField = "/u/.config/ghostty/config:3:font-sise: unknown field"
    private let badTheme = "/u/.config/ghostty/config:9:theme: theme \"Nope\" not found"

    @Test func cleanLoadPresentsNothing() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()

        #expect(policy.decision(forMessages: []) == .unchanged)
    }

    @Test func presentsNewErrorsOnceAndStaysQuietOnRepeatedReloads() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()

        guard case .present(let notice) = policy.decision(forMessages: [unknownField, badTheme]) else {
            Issue.record("expected the first load with errors to present a notice")
            return
        }
        #expect(notice.totalCount == 2)
        #expect(notice.listedDiagnostics.map(\.message) == [unknownField, badTheme])
        #expect(notice.firstFilePath == "/u/.config/ghostty/config")

        // Appearance changes, font zoom, and unrelated edits reload the same errors.
        #expect(policy.decision(forMessages: [unknownField, badTheme]) == .unchanged)
        #expect(policy.decision(forMessages: [badTheme, unknownField]) == .unchanged)
    }

    @Test func changedErrorSetPresentsAgain() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        _ = policy.decision(forMessages: [unknownField])

        let decision = policy.decision(forMessages: [unknownField, badTheme])

        #expect(decision == .present(GhosttyConfigDiagnosticsNotice(
            listedDiagnostics: [unknownField, badTheme].map(GhosttyConfigDiagnostic.init(message:)),
            totalCount: 2
        )))
    }

    @Test func fixingErrorsDismissesAndReintroducingPresentsAgain() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        _ = policy.decision(forMessages: [unknownField])

        #expect(policy.decision(forMessages: []) == .dismiss)
        #expect(policy.decision(forMessages: []) == .unchanged)
        guard case .present = policy.decision(forMessages: [unknownField]) else {
            Issue.record("a reintroduced error must be reported again")
            return
        }
    }

    @Test func dropsCmuxInlineAndDuplicateDiagnostics() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        let inline = "/__cmux_inline__/cmux-shell-integration.conf:1:shell-integration: invalid value"

        #expect(policy.decision(forMessages: [inline]) == .unchanged)
        let decision = policy.decision(forMessages: [unknownField, inline, unknownField, "  "])

        #expect(decision == .present(GhosttyConfigDiagnosticsNotice(
            listedDiagnostics: [GhosttyConfigDiagnostic(message: unknownField)],
            totalCount: 1
        )))
    }

    @Test func filterDropsEveryCmuxOwnedKeyAndKeepsRealErrors() {
        let cmuxKeyMessages = GhosttyConfig.cmuxOwnedKeys.sorted().enumerated().flatMap { index, key in
            [
                "/u/.config/ghostty/config:\(index + 20):\(key): unknown field",
                "\(key): unknown field",
            ]
        }
        let realErrors = [unknownField, badTheme, "font-sise: unknown field", "invalid syntax: sidebar-font-size"]

        let diagnostics = GhosttyConfigDiagnosticsNoticePolicy.userFacingDiagnostics(
            fromMessages: [cmuxKeyMessages[0]] + realErrors + cmuxKeyMessages.dropFirst()
        )

        #expect(diagnostics.map(\.message) == realErrors)
    }

    @Test(arguments: [true, false])
    func onlyCmuxOwnedKeyDiagnosticsShowNoNotice(hasFileLocation: Bool) {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        let messages = [
            "sidebar-font-size: unknown field",
            "surface-tab-bar-font-size: unknown field",
        ].enumerated().map { index, message in
            hasFileLocation ? "/u/.config/ghostty/config:\(index + 1):\(message)" : message
        }

        #expect(policy.decision(forMessages: messages) == .unchanged)
        _ = policy.decision(forMessages: [unknownField])
        #expect(policy.decision(forMessages: messages) == .dismiss)
    }

    @Test(arguments: [true, false])
    func unlistedCountExcludesCmuxOwnedKeys(hasFileLocation: Bool) {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        let real = (1...4).map { "/u/.config/ghostty/config:\($0):key\($0): unknown field" }
        let prefix = hasFileLocation ? "/u/.config/ghostty/config:9:" : ""
        let messages = ["\(prefix)sidebar-font-size: unknown field"] + real
            + ["\(prefix)surface-tab-bar-font-size: unknown field"]

        guard case .present(let notice) = policy.decision(forMessages: messages) else {
            Issue.record("expected a notice")
            return
        }
        #expect(notice.listedDiagnostics.map(\.message) == Array(real.prefix(3)))
        #expect(notice.totalCount == 4)
        #expect(notice.unlistedCount == 1)
    }

    @Test func listsAtMostThreeAndCountsTheRest() {
        var policy = GhosttyConfigDiagnosticsNoticePolicy()
        let messages = (1...5).map { "/u/.config/ghostty/config:\($0):key\($0): unknown field" }

        guard case .present(let notice) = policy.decision(forMessages: messages) else {
            Issue.record("expected a notice")
            return
        }
        #expect(notice.listedDiagnostics.count == GhosttyConfigDiagnosticsNoticePolicy.maximumListedDiagnostics)
        #expect(notice.totalCount == 5)
        #expect(notice.unlistedCount == 2)
    }
}
