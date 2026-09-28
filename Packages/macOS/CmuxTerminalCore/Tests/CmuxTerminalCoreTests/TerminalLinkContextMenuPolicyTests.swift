import Foundation
import Testing
import CmuxTerminalCore

/// The same deterministic browser-domain stand-in ``TerminalLinkRouterTests``
/// uses: hosts containing a dot or equal to localhost are navigable.
private struct StubHostNormalizer: BrowserHostNormalizing {
    var rejectsEveryHost = false

    func normalizedHost(_ rawHost: String) -> String? {
        guard !rejectsEveryHost else { return nil }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains(".") || trimmed == "localhost" else { return nil }
        return trimmed
    }

    func navigableWebURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if URL(string: trimmed)?.scheme != nil { return URL(string: trimmed) }
        guard trimmed.contains(".") || trimmed.lowercased().hasPrefix("localhost") else { return nil }
        return URL(string: "https://\(trimmed)")
    }
}

@Suite struct TerminalLinkContextMenuPolicyTests {
    private let policy = TerminalLinkContextMenuPolicy(
        router: TerminalLinkRouter(hostNormalizer: StubHostNormalizer())
    )

    @Test func aWebLinkOffersBothBrowsersAndCopy() {
        let offer = policy.offer(forCandidate: "https://github.com/manaflow-ai/cmux/issues/847")
        #expect(offer?.url.absoluteString == "https://github.com/manaflow-ai/cmux/issues/847")
        #expect(offer?.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
    }

    @Test func aBareDomainIsTreatedAsTheWebLinkItBecomes() {
        let offer = policy.offer(forCandidate: "example.com/docs")
        #expect(offer?.url.absoluteString == "https://example.com/docs")
        #expect(offer?.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
    }

    @Test func aWebLinkTheEmbeddedBrowserCannotLoadDropsThatItemOnly() {
        let strict = TerminalLinkContextMenuPolicy(
            router: TerminalLinkRouter(hostNormalizer: StubHostNormalizer(rejectsEveryHost: true))
        )
        let offer = strict.offer(forCandidate: "https://example.com/docs")
        #expect(offer?.url.absoluteString == "https://example.com/docs")
        #expect(offer?.items == [.openInDefaultBrowser, .copyLink])
    }

    @Test func aNonBrowserSchemeOffersCopyAlone() {
        let offer = policy.offer(forCandidate: "mailto:someone@example.com")
        #expect(offer?.url.absoluteString == "mailto:someone@example.com")
        #expect(offer?.items == [.copyLink])
    }

    @Test func anAbsoluteFileIsNotALinkAndOffersNothing() {
        #expect(policy.offer(forCandidate: "/Users/someone/notes.md") == nil)
        #expect(policy.offer(forCandidate: "file:///Users/someone/notes.md") == nil)
    }

    @Test func nothingUnderThePointerOffersNothing() {
        #expect(policy.offer(forCandidate: nil) == nil)
        #expect(policy.offer(forCandidate: "") == nil)
        #expect(policy.offer(forCandidate: "   \n ") == nil)
    }

    @Test func ordinaryProseOffersNothing() {
        #expect(policy.offer(forCandidate: "just some words") == nil)
    }

    @Test func surroundingWhitespaceDoesNotChangeTheOffer() {
        let offer = policy.offer(forCandidate: "  https://example.com/docs\n")
        #expect(offer?.url.absoluteString == "https://example.com/docs")
        #expect(offer?.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
    }
}
