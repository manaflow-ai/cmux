@testable import CmuxNextUpdater
import Foundation
import Testing

/// cmux NEXT DEV (`com.cmuxterm.app.debug.next`, the tip feed) and cmux NEXT NIGHTLY
/// (`com.cmuxterm.app.nightly.cmux-next`, the next feed) are different apps. Sparkle installs
/// only a build with the running app's bundle id, so an in-place update must never be offered
/// from the other app's feed: it downloads and then fails to install (#29765, reverted).
/// Each app probes its own feed and nothing else.
@Suite struct UpdateChannelCrossoverTests {
    final class RecordingFeeds: AppcastFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        let values: [String: String]
        init(_ values: [String: String]) { self.values = values }
        var fetched: [String] { lock.withLock { urls } }
        func fetch(_ url: URL) async throws -> Data {
            lock.withLock { urls.append(url.absoluteString) }
            guard let value = values[url.absoluteString] else { throw AppcastParseError(message: "missing \(url)") }
            return Data(value.utf8)
        }
    }

    static let nightlyURL = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    static let tipURL = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"
    static let system = SystemVersion(major: 26, minor: 0, patch: 0)

    static func feed(version: String) -> String {
        """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title><item><sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString><enclosure url="https://example.com/update.dmg" /></item></channel></rss>
        """
    }

    @Test func devIsNeverOfferedTheNightlyFeedsBuild() async throws {
        let dev = UpdateBuildIdentity(bundleIdentifier: UpdateBuildIdentity.tipBundleIdentifier, shortVersion: "0.1.0", build: "100",
                                      minimumSystemVersion: nil, infoFeedURL: Self.tipURL, hasPublicKey: true)
        // The nightly feed has a far newer build; DEV must not see it.
        let feeds = RecordingFeeds([Self.tipURL: Self.feed(version: "200"), Self.nightlyURL: Self.feed(version: "900")])
        let result = try await UpdateProber(fetcher: feeds, architecture: .arm64).probe(dev, system: Self.system)
        #expect(feeds.fetched == [Self.tipURL])
        #expect(result.feedURL == Self.tipURL)
        guard case .updateAvailable(let item) = result.outcome else { Issue.record("expected the tip feed's build"); return }
        #expect(item.version == "200")
    }

    @Test func nightlyIsNeverOfferedTheDevFeedsBuild() async throws {
        let nightly = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly.cmux-next", shortVersion: "0.1.0", build: "100",
                                          minimumSystemVersion: nil, infoFeedURL: Self.nightlyURL, hasPublicKey: true)
        let feeds = RecordingFeeds([Self.nightlyURL: Self.feed(version: "200"), Self.tipURL: Self.feed(version: "900")])
        let result = try await UpdateProber(fetcher: feeds, architecture: .arm64).probe(nightly, system: Self.system)
        #expect(feeds.fetched == [Self.nightlyURL])
        #expect(result.feedURL == Self.nightlyURL)
        guard case .updateAvailable(let item) = result.outcome else { Issue.record("expected the next feed's build"); return }
        #expect(item.version == "200")
    }
}
