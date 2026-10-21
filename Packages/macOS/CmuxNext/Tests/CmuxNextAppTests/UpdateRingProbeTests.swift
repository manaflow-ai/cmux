import CmuxNextSettings
@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The read-only probe (`updates.check`, tagged DEV builds) offers what Sparkle would on the
/// Mac's release ring: items tagged for a faster ring are skipped, untagged items always count.
@Suite struct UpdateRingProbeTests {
    struct StaticFeed: AppcastFetching {
        let xml: String
        func fetch(_ url: URL) async throws -> Data { Data(xml.utf8) }
    }

    static let feed = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
    <item><title>stable</title><sparkle:version>200</sparkle:version><sparkle:channel>cmux-next-stable</sparkle:channel></item>
    <item><title>nightly</title><sparkle:version>300</sparkle:version><sparkle:channel>cmux-next</sparkle:channel></item>
    <item><title>canary</title><sparkle:version>400</sparkle:version><sparkle:channel>cmux-next-canary</sparkle:channel></item>
    <item><title>dev</title><sparkle:version>500</sparkle:version><sparkle:channel>cmux-next-dev</sparkle:channel></item>
    </channel></rss>
    """

    static let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-ring", shortVersion: "1.0.0",
                                              build: "100", minimumSystemVersion: nil,
                                              infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                                              hasPublicKey: false)

    @Test func parserReadsEachItemsSparkleChannel() throws {
        let items = try AppcastParser.parse(Data(Self.feed.utf8))
        #expect(items.map(\.sparkleChannel) == ["cmux-next-stable", "cmux-next", "cmux-next-canary", "cmux-next-dev"])
    }

    @Test(arguments: [(UpdateRing.stable, "200"), (.nightly, "300"), (.canary, "400"), (.dev, "500")])
    func probeOffersTheNewestItemOfTheRingOrASlowerOne(ring: UpdateRing, offered: String) async throws {
        let result = try await UpdateProber(fetcher: StaticFeed(xml: Self.feed), architecture: .arm64)
            .probe(Self.identity, ring: ring, system: SystemVersion(major: 26, minor: 0, patch: 0))
        guard case .updateAvailable(let item) = result.outcome else {
            Issue.record("\(ring): \(result.outcome)")
            return
        }
        #expect(item.version == offered)
    }

    @Test func untaggedItemsAreOfferedOnEveryRing() {
        let item = AppcastItem(version: "1")
        for ring in UpdateRing.allCases {
            #expect(item.isOffered(allowing: ring.acceptedSparkleChannels))
        }
        #expect(!AppcastItem(version: "1", sparkleChannel: "cmux-next-dev").isOffered(allowing: UpdateRing.canary.acceptedSparkleChannels))
    }

    /// `updates.channel` defaults to Nightly (unchanged behavior) and its values name the rings.
    @Test func channelSettingDefaultsToNightlyAndMapsOntoRings() {
        #expect(UpdatesSettings().channel == .nightly)
        for setting in UpdatesChannelSetting.allCases {
            #expect(UpdateRing(rawValue: setting.rawValue) != nil, "\(setting)")
        }
        #expect(UpdatesChannelSetting.allCases.map(\.rawValue) == UpdateRing.allCases.map(\.rawValue))
    }
}
