import Foundation
import Testing
import CmuxTerminalCore

/// A deterministic stand-in for the browser domain, matching production's
/// permissiveness on the two points that decide this policy's hard cases:
/// scheme-less text containing a dot or a slash becomes an HTTPS URL, and any
/// non-empty host normalizes. Production's `BrowserURLResolver` and
/// `RemoteLoopbackProxyAlias` both behave this way, which is why the policy
/// cannot lean on them to reject `src/config/url.zig`.
private struct StubHostNormalizer: BrowserHostNormalizing {
    var rejectsEveryHost = false

    func normalizedHost(_ rawHost: String) -> String? {
        guard !rejectsEveryHost else { return nil }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func navigableWebURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        // Foundation reads `localhost:8000` as a custom scheme; production's
        // resolver recognizes the host:port form first, so the stub does too.
        if trimmed.lowercased().hasPrefix("localhost"), !trimmed.contains("://") {
            return URL(string: "http://\(trimmed)")
        }
        if URL(string: trimmed)?.scheme != nil { return URL(string: trimmed) }
        guard trimmed.contains(".") || trimmed.contains("/") || trimmed.contains(":") else { return nil }
        return URL(string: "https://\(trimmed)")
    }
}

@Suite struct TerminalLinkContextMenuPolicyTests {
    private static func makePolicy(
        rejectsEveryHost: Bool = false,
        embeddedBrowserIsAvailable: Bool = true,
        existingFiles: Set<String> = []
    ) -> TerminalLinkContextMenuPolicy {
        TerminalLinkContextMenuPolicy(
            router: TerminalLinkRouter(
                hostNormalizer: StubHostNormalizer(rejectsEveryHost: rejectsEveryHost)
            ),
            embeddedBrowserIsAvailable: embeddedBrowserIsAvailable,
            pathResolver: TerminalPathResolver { existingFiles.contains($0) }
        )
    }

    private let policy = makePolicy()

    @Test func aWebLinkOffersBothBrowsersAndCopy() throws {
        let offer = try #require(
            policy.offer(
                forCandidate: "https://github.com/manaflow-ai/cmux/issues/847",
                fileResolution: .localFilesystem(cwd: "/tmp")
            )
        )
        #expect(offer.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
        #expect(offer.url.absoluteString == "https://github.com/manaflow-ai/cmux/issues/847")
        #expect(offer.rawValue == "https://github.com/manaflow-ai/cmux/issues/847")
    }

    @Test func aBareDomainIsTreatedAsTheWebLinkItBecomes() throws {
        let offer = try #require(
            policy.offer(forCandidate: "example.com/docs", fileResolution: .localFilesystem(cwd: nil))
        )
        #expect(offer.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
        #expect(offer.url.absoluteString == "https://example.com/docs")
    }

    @Test func theRawTextIsCarriedAlongsideTheResolvedURL() throws {
        // The open items replay this through the coordinator, which resolves
        // it the way a click does. Handing over the resolved URL instead would
        // skip the coordinator's own file and remote-pane guards.
        let offer = try #require(
            policy.offer(forCandidate: "  example.com/docs  ", fileResolution: .remoteHost)
        )
        #expect(offer.rawValue == "example.com/docs")
        #expect(offer.url.absoluteString == "https://example.com/docs")
    }

    @Test func anExistingRelativePathIsAFileAndOffersNothing() {
        // Ghostty highlights bare relative paths, so this text arrives here as
        // a hovered "link". Cmd-click opens it in the editor; the menu must not
        // offer to open `https://src/config/url.zig` beside that.
        let withFile = Self.makePolicy(existingFiles: ["/repo/src/config/url.zig"])
        #expect(
            withFile.offer(
                forCandidate: "src/config/url.zig",
                fileResolution: .localFilesystem(cwd: "/repo")
            ) == nil
        )
    }

    @Test func aRelativePathThatIsNotOnThisMachineStillOffersNothing() {
        // Same text, but the pane's cwd does not contain it, or the pane is on
        // another host entirely. The invented host `src` is the giveaway.
        #expect(
            policy.offer(
                forCandidate: "src/config/url.zig",
                fileResolution: .localFilesystem(cwd: "/repo")
            ) == nil
        )
        #expect(
            policy.offer(forCandidate: "src/config/url.zig", fileResolution: .remoteHost) == nil
        )
    }

    @Test func aRelativePathWithALineSuffixOffersNothing() {
        #expect(
            policy.offer(
                forCandidate: "Sources/GhosttyTerminalView.swift:3349",
                fileResolution: .remoteHost
            ) == nil
        )
    }

    @Test func localhostKeepsItsOfferDespiteHavingNoDot() throws {
        let offer = try #require(
            policy.offer(forCandidate: "localhost:8000/health", fileResolution: .remoteHost)
        )
        #expect(offer.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
    }

    @Test func aWebLinkTheEmbeddedBrowserCannotLoadDropsThatItemOnly() throws {
        let rejecting = Self.makePolicy(rejectsEveryHost: true)
        let offer = try #require(
            rejecting.offer(
                forCandidate: "https://example.com/path",
                fileResolution: .localFilesystem(cwd: nil)
            )
        )
        #expect(offer.items == [.openInDefaultBrowser, .copyLink])
    }

    @Test func aDisabledEmbeddedBrowserDropsThatItemOnly() throws {
        // Switched off by the user or by an MDM profile. Showing the item and
        // silently opening the system browser would make the label a lie.
        let disabled = Self.makePolicy(embeddedBrowserIsAvailable: false)
        let offer = try #require(
            disabled.offer(
                forCandidate: "https://example.com/path",
                fileResolution: .localFilesystem(cwd: nil)
            )
        )
        #expect(offer.items == [.openInDefaultBrowser, .copyLink])
    }

    @Test func aNonBrowserSchemeOffersCopyAlone() throws {
        let offer = try #require(
            policy.offer(forCandidate: "mailto:team@example.com", fileResolution: .remoteHost)
        )
        #expect(offer.items == [.copyLink])
        #expect(offer.url.scheme == "mailto")
    }

    @Test func anAbsoluteFileIsNotALinkAndOffersNothing() {
        #expect(policy.offer(forCandidate: "/tmp/notes.txt", fileResolution: .remoteHost) == nil)
        #expect(policy.offer(forCandidate: "file:///tmp/notes.txt", fileResolution: .remoteHost) == nil)
    }

    @Test func nothingUnderThePointerOffersNothing() {
        #expect(policy.offer(forCandidate: nil, fileResolution: .remoteHost) == nil)
        #expect(policy.offer(forCandidate: "   \n ", fileResolution: .remoteHost) == nil)
    }

    @Test func ordinaryProseOffersNothing() {
        #expect(policy.offer(forCandidate: "hello", fileResolution: .remoteHost) == nil)
    }

    @Test func surroundingWhitespaceDoesNotChangeTheOffer() throws {
        let offer = try #require(
            policy.offer(
                forCandidate: "  https://example.com/a\n",
                fileResolution: .remoteHost
            )
        )
        #expect(offer.url.absoluteString == "https://example.com/a")
        #expect(offer.items == [.openInCmuxBrowser, .openInDefaultBrowser, .copyLink])
    }
}
