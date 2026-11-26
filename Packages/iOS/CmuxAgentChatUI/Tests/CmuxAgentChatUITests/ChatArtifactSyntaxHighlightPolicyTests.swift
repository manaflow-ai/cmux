import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact syntax highlighting policy")
struct ChatArtifactSyntaxHighlightPolicyTests {
    private let policy = ChatArtifactSyntaxHighlightPolicy()

    @Test("known languages highlight through the exact size limit")
    func highlightsAtThreshold() {
        #expect(policy.decision(
            path: "/tmp/example.swift",
            byteCount: ChatArtifactSyntaxHighlightPolicy.maxHighlightBytes
        ) == .highlight(language: "swift"))
    }

    @Test("purescript artifacts highlight through the haskell grammar")
    func highlightsPureScriptThroughHaskell() {
        #expect(policy.inferredLanguage(path: "/tmp/Main.purs") == "haskell")
    }

    @Test("haskell artifacts highlight directly")
    func highlightsHaskell() {
        #expect(policy.inferredLanguage(path: "/tmp/Main.hs") == "haskell")
    }

    @Test("files over the limit skip for size and show the pill")
    func skipsOverThreshold() {
        let decision = policy.decision(
            path: "/tmp/example.swift",
            byteCount: ChatArtifactSyntaxHighlightPolicy.maxHighlightBytes + 1
        )

        #expect(decision == .skippedForSize)
        #expect(decision.showsHighlightingOffPill)
    }

    @Test("unknown small files use detection without showing the pill")
    func detectsOnlySmallUnknownFiles() {
        let small = policy.decision(
            path: "/tmp/extensionless",
            byteCount: ChatArtifactSyntaxHighlightPolicy.maxAutomaticDetectionBytes - 1
        )
        let larger = policy.decision(
            path: "/tmp/server.log",
            byteCount: ChatArtifactSyntaxHighlightPolicy.maxAutomaticDetectionBytes
        )

        #expect(small == .highlight(language: nil))
        #expect(!small.showsHighlightingOffPill)
        #expect(larger == .skippedNoLanguage)
        #expect(!larger.showsHighlightingOffPill)
    }
}
