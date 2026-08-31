import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The Mac-update floor notice is audience-gated: dogfood channels by
/// default (its revert path is a TestFlight instruction), remotely widened
/// or killed through `/api/whats-new`'s `macUpdateNoticeAudience`.
@MainActor
@Suite struct MobileWhatsNewNoticeAudienceTests {
    @Test func absentAndUnknownAudiencesFallBackToBeta() {
        #expect(MobileWhatsNewNoticeAudience.resolve(nil) == .beta)
        #expect(MobileWhatsNewNoticeAudience.resolve("founders") == .beta)
        #expect(MobileWhatsNewNoticeAudience.resolve("all") == .all)
        #expect(MobileWhatsNewNoticeAudience.resolve("none") == .none)
    }

    @Test func betaAudienceMatchesDogfoodChannelsOnly() {
        let audience = MobileWhatsNewNoticeAudience.beta
        #expect(audience.allows(.dev))
        #expect(audience.allows(.beta))
        #expect(audience.allows(.internal))
        #expect(!audience.allows(.demo))
        #expect(!audience.allows(.prod))
        #expect(MobileWhatsNewNoticeAudience.all.allows(.prod))
        #expect(!MobileWhatsNewNoticeAudience.none.allows(.beta))
    }

    @Test func neverFetchedListShowsNoticeToBetaAndHidesFromAppStore() {
        let beta = center(buildType: .beta)
        #expect(footnotes(of: beta).allSatisfy { $0 != nil })

        let appStore = center(buildType: .prod)
        #expect(footnotes(of: appStore).allSatisfy { $0 == nil })
        // Only the notice is stripped; the page itself stays visible.
        #expect(!appStore.visibleBinaryEntries.isEmpty)
    }

    @Test func remoteAudienceOverridesTheDefault() async {
        let widened = center(buildType: .prod, remoteAudience: "all")
        await widened.refresh()
        #expect(footnotes(of: widened).allSatisfy { $0 != nil })

        let killed = center(buildType: .beta, remoteAudience: "none")
        await killed.refresh()
        #expect(footnotes(of: killed).allSatisfy { $0 == nil })

        // The sheet path reads the same gated list.
        #expect(killed.unseenPages.allSatisfy { $0.footnote == nil })
    }

    @Test func unknownRemoteAudienceStaysProtective() async {
        let betaBuild = center(buildType: .beta, remoteAudience: "everyone-someday")
        await betaBuild.refresh()
        #expect(footnotes(of: betaBuild).allSatisfy { $0 != nil })

        let appStoreBuild = center(buildType: .prod, remoteAudience: "everyone-someday")
        await appStoreBuild.refresh()
        #expect(footnotes(of: appStoreBuild).allSatisfy { $0 == nil })
    }

    private func footnotes(of center: MobileWhatsNewCenter) -> [String?] {
        center.visibleBinaryEntries.map(\.footnote)
    }

    private func center(
        buildType: MobileBuildType,
        remoteAudience: String? = nil
    ) -> MobileWhatsNewCenter {
        let suiteName = "MobileWhatsNewNoticeAudienceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let ids = MobileWhatsNewCatalog.entries.map { "\"\($0.id)\"" }.joined(separator: ",")
        let audienceField = remoteAudience.map { ",\"macUpdateNoticeAudience\":\"\($0)\"" } ?? ""
        let payload = Data(
            "{\"visibleEntryIds\":[\(ids)],\"announcements\":[]\(audienceField)}".utf8
        )
        return MobileWhatsNewCenter(
            apiBaseURL: "https://whats-new.test",
            buildType: buildType,
            appVersion: "1.0.5",
            defaults: defaults,
            loader: { _ in payload }
        )
    }
}
