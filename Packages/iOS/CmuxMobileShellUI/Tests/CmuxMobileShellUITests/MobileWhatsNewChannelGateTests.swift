#if os(iOS)
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The What's New surfaces (one-time launch sheet, Settings archive row)
/// announce team-lane features, which contributed to the App Store app's
/// Guideline 2.2 rejection (submission 591a59e6). Official (`.prod`) builds
/// must therefore show NO What's New content by default — before the first
/// fetch and after it — unless the remote catalog explicitly targets the
/// "prod" channel for a specific entry or announcement. Team builds keep
/// today's behavior.
@MainActor
@Suite struct MobileWhatsNewChannelGateTests {
    private func makeCenter(
        buildType: MobileBuildType,
        payload: String? = nil
    ) -> MobileWhatsNewCenter {
        let suiteName = "MobileWhatsNewChannelGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MobileWhatsNewCenter(
            apiBaseURL: "https://cmux.test",
            appVersion: "1.0.5",
            buildType: buildType,
            defaults: defaults,
            loader: { _ in
                guard let payload else { throw URLError(.notConnectedToInternet) }
                return Data(payload.utf8)
            }
        )
    }

    @Test func neverFetchedOfficialBuildShowsNoWhatsNewAtAll() {
        let center = makeCenter(buildType: .prod)
        // The never-fetched fail-open to binary truth stays inside the
        // channel gate: catalog entries default to team lanes, so the
        // official app has no sheet pages and no archive rows.
        #expect(center.visibleBinaryEntries.isEmpty)
        #expect(center.archivePages.isEmpty)
        #expect(center.unseenPages.isEmpty)
    }

    @Test func neverFetchedTeamBuildsKeepTheFullCatalog() {
        for buildType in [MobileBuildType.dev, .beta, .internal] {
            let center = makeCenter(buildType: buildType)
            #expect(
                center.visibleBinaryEntries.map(\.id)
                    == MobileWhatsNewCatalog.entries.map(\.id)
            )
            #expect(!center.unseenPages.isEmpty)
        }
    }

    @Test func legacyPayloadWithoutChannelFieldsKeepsTeamBehavior() async {
        // The pre-channel server payload shape must keep decoding and must
        // keep meaning "team lanes only" (not "everyone").
        let payload = #"{"visibleEntryIds":["connections.v1"],"announcements":[]}"#
        let team = makeCenter(buildType: .beta, payload: payload)
        await team.refresh()
        #expect(team.visibleBinaryEntries.map(\.id) == ["connections.v1"])

        let official = makeCenter(buildType: .prod, payload: payload)
        await official.refresh()
        #expect(official.visibleBinaryEntries.isEmpty)
        #expect(official.unseenPages.isEmpty)
    }

    @Test func remoteEntryChannelsOptABinaryEntryIntoOfficial() async {
        let payload = #"""
        {
          "visibleEntryIds": ["connections.v1"],
          "entryChannels": { "connections.v1": ["dev", "beta", "internal", "prod"] },
          "announcements": []
        }
        """#
        let center = makeCenter(buildType: .prod, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.map(\.id) == ["connections.v1"])
        #expect(center.unseenPages.map(\.id) == ["connections.v1"])
    }

    @Test func remoteEntryChannelsCanAlsoNarrowTeamBuilds() async {
        // The remote override REPLACES the compiled-in declaration, so an
        // operator can retract an entry from a single lane remotely.
        let payload = #"""
        {
          "visibleEntryIds": ["connections.v1"],
          "entryChannels": { "connections.v1": ["prod"] },
          "announcements": []
        }
        """#
        let center = makeCenter(buildType: .beta, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.isEmpty)
    }

    @Test func announcementsDefaultToTeamLanesOnly() async {
        let payload = #"""
        {
          "visibleEntryIds": [],
          "announcements": [
            {
              "id": "service.notice",
              "minVersion": "1.0",
              "maxVersion": "2.0",
              "title": "Service notice",
              "features": [{ "title": "News", "detail": "Something changed." }]
            }
          ]
        }
        """#
        let team = makeCenter(buildType: .internal, payload: payload)
        await team.refresh()
        #expect(team.announcementPages.map(\.id) == ["service.notice"])

        let official = makeCenter(buildType: .prod, payload: payload)
        await official.refresh()
        #expect(official.announcementPages.isEmpty)
        #expect(official.unseenPages.isEmpty)
    }

    @Test func announcementWithProdChannelReachesTheOfficialApp() async {
        let payload = #"""
        {
          "visibleEntryIds": [],
          "announcements": [
            {
              "id": "official.notice",
              "minVersion": "1.0",
              "maxVersion": "2.0",
              "title": "Official notice",
              "channels": ["prod"],
              "features": [{ "title": "News", "detail": "Something changed." }]
            }
          ]
        }
        """#
        let center = makeCenter(buildType: .prod, payload: payload)
        await center.refresh()
        #expect(center.announcementPages.map(\.id) == ["official.notice"])
        #expect(center.unseenPages.map(\.id) == ["official.notice"])
        // And per the explicit-list-replaces-default rule, that prod-only
        // announcement stays off team builds.
        let team = makeCenter(buildType: .beta, payload: payload)
        await team.refresh()
        #expect(team.announcementPages.isEmpty)
    }
}
#endif
