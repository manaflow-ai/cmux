@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

@Suite struct UpdateChannelCrossoverTests {
    struct Feeds: AppcastFetching {
        let values: [String: String]
        func fetch(_ url: URL) async throws -> Data {
            guard let value = values[url.absoluteString] else { throw AppcastParseError(message: "missing (url)") }
            return Data(value.utf8)
        }
    }

    struct Comparator: SourceCommitComparing {
        let relation: SourceCommitRelation
        func compare(_ lhs: String, _ rhs: String) async -> SourceCommitRelation { relation }
    }

    static let nightlyURL = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    static let tipURL = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"
    static let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next", shortVersion: "0.1.0",
                                              build: "100", minimumSystemVersion: SystemVersion(major: 26, minor: 0, patch: 0),
                                              infoFeedURL: nightlyURL, hasPublicKey: true, sourceCommit: "1111111")

    static func feed(version: String, commit: String) -> String {
        """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:cmux="https://cmux.com/xml-namespaces/cmux"><channel><title>cmux NEXT</title><item><sparkle:version>(version)</sparkle:version><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString><cmux:sourceCommit>(commit)</cmux:sourceCommit><enclosure url="https://example.com/update.dmg" /></item></channel></rss>
        """
    }

    static func prober(current: String, counterpart: String, relation: SourceCommitRelation) -> UpdateProber {
        UpdateProber(fetcher: Feeds(values: [nightlyURL: current, tipURL: counterpart]), architecture: .arm64,
                     sourceComparator: Comparator(relation: relation))
    }

    @Test func newerDevSourceWins() async throws {
        let result = try await Self.prober(current: Self.feed(version: "200", commit: "2222222"),
                                           counterpart: Self.feed(version: "300", commit: "3333333"), relation: .older)
            .probeCrossChannel(Self.identity, system: SystemVersion(major: 26, minor: 0, patch: 0))
        #expect(result.feedURL == Self.tipURL)
        guard case .updateAvailable(let item) = result.outcome else { Issue.record("expected update"); return }
        #expect(item.version == "300")
    }

    @Test func olderDevSourceIsNeverOfferedEvenWithHigherBuildNumber() async throws {
        let result = try await Self.prober(current: Self.feed(version: "300", commit: "3333333"),
                                           counterpart: Self.feed(version: "900", commit: "2222222"), relation: .newer)
            .probeCrossChannel(Self.identity, system: SystemVersion(major: 26, minor: 0, patch: 0))
        #expect(result.feedURL == Self.nightlyURL)
        guard case .updateAvailable(let item) = result.outcome else { Issue.record("expected current-feed update"); return }
        #expect(item.version == "300")
    }

    @Test func equalSourceCommitKeepsCurrentFeed() async throws {
        let result = try await Self.prober(current: Self.feed(version: "200", commit: "3333333"),
                                           counterpart: Self.feed(version: "300", commit: "3333333"), relation: .equal)
            .probeCrossChannel(Self.identity, system: SystemVersion(major: 26, minor: 0, patch: 0))
        #expect(result.feedURL == Self.nightlyURL)
    }

    @Test func parserReadsSourceCommitAndReleaseNotesFallback() throws {
        let custom = try #require(AppcastParser.parse(Data(Self.feed(version: "200", commit: "abcdef1").utf8)).first)
        #expect(custom.sourceCommit == "abcdef1")
        let fallback = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1</sparkle:version><sparkle:fullReleaseNotesLink>https://github.com/manaflow-ai/cmux/commit/abcdef1234567</sparkle:fullReleaseNotesLink></item></channel></rss>
        """
        #expect(try AppcastParser.parse(Data(fallback.utf8)).first?.sourceCommit == "abcdef1234567")
    }
}
