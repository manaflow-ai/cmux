import Testing
@testable import CmuxUpdater

/// Release rings (`updates.channel`) are a ladder of `sparkle:channel` tags in the one
/// cmux-next appcast: a faster ring accepts every slower ring's items as well.
@Suite struct UpdateRingTests {
    @Test func eachRingAcceptsItsOwnTagAndEverySlowerRing() {
        #expect(UpdateRing.stable.acceptedSparkleChannels == ["cmux-next-stable"])
        #expect(UpdateRing.nightly.acceptedSparkleChannels == ["cmux-next-stable", "cmux-next"])
        #expect(UpdateRing.canary.acceptedSparkleChannels == ["cmux-next-stable", "cmux-next", "cmux-next-canary"])
        #expect(UpdateRing.dev.acceptedSparkleChannels == ["cmux-next-stable", "cmux-next", "cmux-next-canary", "cmux-next-dev"])
    }

    /// Nightly is what every cmux-next build accepted before rings, so the default is unchanged.
    @Test func nightlyRingKeepsTheTagEveryPublishedItemCarries() {
        #expect(UpdateRing.nightly.sparkleChannel == UpdateFeedResolver.Channel.nightlyNextSparkleChannel)
        let feed = UpdateFeedResolver().resolve(infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")
        #expect(feed.channel.allowedSparkleChannels == feed.channel.allowedSparkleChannels(ring: .nightly))
    }

    /// Only the cmux-next feed has rings: stable, NIGHTLY and RC never accept a tagged item.
    @Test func otherFeedsAcceptNoTaggedItemOnAnyRing() {
        let resolver = UpdateFeedResolver()
        for feed in ["https://files.cmux.com/nightly/appcast.xml", "https://files.cmux.com/rc/appcast.xml",
                     "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"] {
            for ring in UpdateRing.allCases {
                #expect(resolver.resolve(infoFeedURL: feed).channel.allowedSparkleChannels(ring: ring).isEmpty, "\(feed) \(ring)")
            }
        }
    }
}
