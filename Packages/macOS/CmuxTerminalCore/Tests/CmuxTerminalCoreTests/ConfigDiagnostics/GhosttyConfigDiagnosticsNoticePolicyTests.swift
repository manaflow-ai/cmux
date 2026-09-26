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
