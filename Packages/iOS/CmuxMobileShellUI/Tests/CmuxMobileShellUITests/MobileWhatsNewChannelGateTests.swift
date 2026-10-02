#if os(iOS)
import CmuxMobileShell
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
        payload: String? = nil,
        acknowledgedEntryID: String? = nil,
        appVersion: String = "1.0.6",
        preferredLanguages: [String] = ["en"]
    ) -> MobileWhatsNewCenter {
        let suiteName = "MobileWhatsNewChannelGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let acknowledgedEntryID {
            defaults.set(
                acknowledgedEntryID,
                forKey: MobileWhatsNewCenter.markerKey
            )
        }
        return MobileWhatsNewCenter(
            apiBaseURL: "https://cmux.test",
            appVersion: appVersion,
            buildType: buildType,
            defaults: defaults,
            preferredLanguages: preferredLanguages,
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

    @Test func failedInitialRefreshStillAllowsOfflinePairingGuidance() async {
        let center = makeCenter(buildType: .beta, acknowledgedEntryID: "connections.v2")
        #expect(!center.hasCompletedInitialRefresh)
        await center.refresh()
        #expect(center.hasCompletedInitialRefresh)
        #expect(!center.lastRefreshSucceeded)
        #expect(center.unseenPages.map(\.id) == ["pairing.1.0.6"])
    }

    @Test func cancelledInitialRefreshWaitsForTheNextCompletedAttempt() async {
        let gate = RefreshGate()
        let defaults = UserDefaults(suiteName: "CancelledWhatsNew-\(UUID().uuidString)")!
        defaults.set("connections.v2", forKey: MobileWhatsNewCenter.markerKey)
        let center = MobileWhatsNewCenter(
            apiBaseURL: "https://cmux.test", appVersion: "1.0.6",
            buildType: .beta, defaults: defaults,
            loader: { _ in try await gate.load() }
        )
        let first = Task { await center.refresh() }
        await gate.waitUntilStarted()
        first.cancel()
        gate.finish(.failure(CancellationError()))
        await first.value
        #expect(!center.hasCompletedInitialRefresh)
        #expect(!center.lastRefreshSucceeded)

        let second = Task { await center.refresh() }
        await gate.waitUntilStarted()
        #expect(!center.hasCompletedInitialRefresh)
        gate.finish(.success(Data(#"""
        {"visibleEntryIds":["pairing.1.0.6"],"announcements":[{
          "id":"release","minVersion":"1.0.6","maxVersion":"1.0.6",
          "channels":["beta"],"title":"Release notice",
          "features":[{"title":"Update your Mac","detail":"New Mac required."}]
        }]}
        """#.utf8)))
        await second.value
        #expect(center.hasCompletedInitialRefresh)
        #expect(center.unseenPages.map(\.id) == ["release", "pairing.1.0.6"])
    }

    @MainActor
    private final class RefreshGate {
        private var pending: CheckedContinuation<Data, any Error>?
        private var started: CheckedContinuation<Void, Never>?

        func load() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            guard pending == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ result: Result<Data, any Error>) {
            pending?.resume(with: result)
            pending = nil
        }
    }

    @Test(arguments: [
        (["ja-JP"], "新機能", "更新してください"),
        (["zh-Hant-TW"], "更新內容", "請更新"),
        (["xx"], "Release notice", "Update your Mac")
    ])
    func announcementUsesAppLanguageAndRetainsEnglishFallback(
        languages: [String], title: String, detail: String
    ) async throws {
        let center = makeCenter(
            buildType: .beta,
            payload: #"""
            {"visibleEntryIds":["pairing.1.0.6"],"announcements":[{
              "id":"release","minVersion":"1.0.6","maxVersion":"1.0.6",
              "channels":["beta"],"title":"Release notice",
              "features":[{"title":"Mac","detail":"Update your Mac"}],
              "localizations":{
                "en":{"title":"Release notice","features":[{"title":"Mac","detail":"Update your Mac"}]},
                "ja":{"title":"新機能","features":[{"title":"Mac","detail":"更新してください"}]},
                "zh-TW":{"title":"更新內容","features":[{"title":"Mac","detail":"請更新"}]}
              }
            }]}
            """#,
            preferredLanguages: languages
        )
        await center.refresh()
        let page = try #require(center.announcementPages.first)
        #expect(page.id == "release")
        #expect(page.title == title)
        guard case .features(let features) = page.body else {
            Issue.record("Expected translated feature rows")
            return
        }
        #expect(features.first?.detail == detail)
        center.acknowledge([page])
        #expect(!center.unseenPages.contains { $0.id == "release" })
    }

    @Test func pinpointNoticeOnlyReachesItsVersionAndChannels() async {
        let payload = #"""
        {"visibleEntryIds":["pairing.1.0.6","connections.v1"],"announcements":[{
          "id":"ios-1.0.6-connections","minVersion":"1.0.6","maxVersion":"1.0.6",
          "channels":["beta","internal"],"title":"What's New in 1.0.6",
          "features":[{"title":"Update your Mac","detail":"Requires cmux 0.64.25."}]
        }]}
        """#
        for channel in [MobileBuildType.beta, .internal, .dev, .prod, .demo] {
            for appVersion in ["1.0.4", "1.0.5", "1.0.6", "1.0.7"] {
                let center = makeCenter(
                    buildType: channel,
                    payload: payload,
                    acknowledgedEntryID: "pairing.1.0.6",
                    appVersion: appVersion
                )
                await center.refresh()
                let shouldShow = appVersion == "1.0.6" && (channel == .beta || channel == .internal)
                #expect(center.unseenPages.map(\.id) == (shouldShow ? ["ios-1.0.6-connections"] : []))
                if shouldShow {
                    center.acknowledge(center.unseenPages)
                    await center.refresh()
                    #expect(center.unseenPages.isEmpty)
                    #expect(center.announcementPages.count == 1)
                }
            }
        }
    }

    @Test func announcementIsFollowedByPairingSetupOnlyOn106() async throws {
        let payload = #"""
        {"visibleEntryIds":["pairing.1.0.6","connections.v1"],"announcements":[{
          "id":"ios-1.0.6-connections","minVersion":"1.0.6","maxVersion":"1.0.6",
          "channels":["beta","internal"],"title":"What's New in 1.0.6",
          "features":[{"title":"Update your Mac","detail":"Requires cmux 0.64.25."}]
        }]}
        """#
        for channel in [MobileBuildType.beta, .internal] {
            for marker in ["connections.v1", "connections.v2", "pairing-opt-in.v1"] {
                let center = makeCenter(
                    buildType: channel, payload: payload,
                    acknowledgedEntryID: marker, appVersion: "1.0.6"
                )
                #expect(!center.hasCompletedInitialRefresh)
                await center.refresh()
                #expect(center.hasCompletedInitialRefresh)
                #expect(center.unseenPages.map(\.id) == ["ios-1.0.6-connections", "pairing.1.0.6"])
                let pairing = try #require(center.unseenPages.last)
                #expect(pairing.releaseLabel == "1.0.6 · September 2026")
                center.acknowledge(center.unseenPages)
                await center.refresh()
                #expect(center.unseenPages.isEmpty)
            }
            for version in ["1.0.5", "1.0.7"] {
                let center = makeCenter(
                    buildType: channel, payload: payload,
                    acknowledgedEntryID: "connections.v2", appVersion: version
                )
                await center.refresh()
                #expect(center.unseenPages.isEmpty)
                #expect(!center.archivePages.contains { $0.id == "pairing.1.0.6" })
            }
        }
        for version in ["1.0.5", "1.0.7"] {
            let center = makeCenter(buildType: .beta, appVersion: version)
            #expect(!center.visibleBinaryEntries.contains { $0.id == "pairing.1.0.6" })
            #expect(!MobileWhatsNewCatalog().channelVisibleEntries(buildType: .beta, appVersion: version)
                .contains { $0.id == "pairing.1.0.6" })
        }
    }

    @Test func pairingUpdateAppearsAfterAnOlderPageWasAcknowledged() async {
        let payload = #"""
        {
          "visibleEntryIds": ["pairing.1.0.6", "connections.v1"],
          "announcements": []
        }
        """#
        for oldMarker in ["pairing-opt-in.v1", "connections.v1", "connections.v2"] {
            let center = makeCenter(
                buildType: .beta,
                payload: payload,
                acknowledgedEntryID: oldMarker
            )
            await center.refresh()
            #expect(center.unseenPages.map(\.id) == ["pairing.1.0.6"])
        }
    }

    @Test func pairingPageFocusesOnPairingRequirement() throws {
        let page = try #require(MobileWhatsNewCatalog().entry(withID: "pairing.1.0.6"))
        guard case .pairingSetup(let features) = page.body else {
            Issue.record("pairing.1.0.6 should render the custom pairing page")
            return
        }
        #expect(features.isEmpty)
        #expect(page.title == "Action Required: Enable iOS pairing on your Mac")
        #expect(MobileWhatsNewCatalog().entry(withID: "pairing-opt-in.v1") == nil)
    }

    @Test func archiveKeepsBothUpdatesAfterAcknowledgingPairing() async throws {
        let center = makeCenter(
            buildType: .beta,
            payload: #"{"visibleEntryIds":["pairing.1.0.6","connections.v1"],"announcements":[]}"#
        )
        await center.refresh()
        #expect(center.archivePages.map(\.id) == ["pairing.1.0.6", "connections.v1"])
        #expect(center.unseenPages.map(\.id) == ["pairing.1.0.6", "connections.v1"])
        let oldPage = try #require(MobileWhatsNewCatalog().entry(withID: "connections.v1"))
        guard case .features(let features) = oldPage.body else {
            Issue.record("The earlier connection update must keep its feature rows")
            return
        }
        #expect(features.map(\.symbol) == ["desktopcomputer.and.macbook", "bolt.horizontal", "network", "qrcode.viewfinder"])
        center.acknowledge(center.unseenPages)
        #expect(center.unseenPages.isEmpty)
        #expect(center.archivePages.count == 2)
        center.acknowledge([oldPage])
        #expect(center.unseenPages.isEmpty)
    }

    @Test func compatibilityCopyUsesTheRemotePolicyShape() {
        let beta = MobileWhatsNewCatalog().macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .beta
        )
        #expect(beta.stableVersion == "0.64.20")
        #expect(beta.nightlyVersion == "0.64.22-nightly.3345650013202")

        let official = MobileWhatsNewCatalog().macCompatibility(
            policy: .baked,
            iosVersion: "1.0.4",
            buildType: .prod
        )
        #expect(official.stableVersion == "0.64.25")
        #expect(official.nightlyVersion == "0.64.25-nightly.3522337919701")
    }

    @Test func neverFetchedTeamBuildsKeepTheFullCatalog() {
        for buildType in [MobileBuildType.dev, .beta, .internal] {
            let center = makeCenter(buildType: buildType)
            #expect(
                center.visibleBinaryEntries.map(\.id)
                    == MobileWhatsNewCatalog().channelVisibleEntries(buildType: buildType, appVersion: "1.0.6").map(\.id)
            )
            #expect(!center.unseenPages.isEmpty)
        }
    }

    @Test func legacyPayloadWithoutChannelFieldsKeepsTeamBehavior() async {
        // The pre-channel server payload shape must keep decoding and must
        // keep meaning "team lanes only" (not "everyone").
        let payload = #"{"visibleEntryIds":["pairing.1.0.6"],"announcements":[]}"#
        let team = makeCenter(buildType: .beta, payload: payload)
        await team.refresh()
        #expect(team.visibleBinaryEntries.map(\.id) == ["pairing.1.0.6"])

        let official = makeCenter(buildType: .prod, payload: payload)
        await official.refresh()
        #expect(official.visibleBinaryEntries.isEmpty)
        #expect(official.unseenPages.isEmpty)
    }

    @Test func staleServerCatalogKeepsCurrentNativePageAvailable() async {
        let payload = #"{"visibleEntryIds":["retired.v1"],"announcements":[]}"#
        let center = makeCenter(buildType: .beta, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.map(\.id) == ["pairing.1.0.6", "connections.v1"])
        #expect(center.archivePages.map(\.id) == ["pairing.1.0.6", "connections.v1"])
    }

    @Test func oldServerCatalogCannotHidePairingRequirement() async {
        let payload = #"{"visibleEntryIds":["connections.v1"],"announcements":[]}"#
        let center = makeCenter(buildType: .beta, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.map(\.id) == ["pairing.1.0.6", "connections.v1"])
        #expect(center.unseenPages.map(\.id) == ["pairing.1.0.6", "connections.v1"])
    }

    @Test func explicitEmptyServerCatalogStillHidesNativePages() async {
        let payload = #"{"visibleEntryIds":[],"announcements":[]}"#
        let center = makeCenter(buildType: .beta, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.isEmpty)
        #expect(center.archivePages.isEmpty)
    }

    @Test func remoteEntryChannelsOptABinaryEntryIntoOfficial() async {
        let payload = #"""
        {
          "visibleEntryIds": ["pairing.1.0.6"],
          "entryChannels": { "pairing.1.0.6": ["dev", "beta", "internal", "prod"] },
          "announcements": []
        }
        """#
        let center = makeCenter(buildType: .prod, payload: payload)
        await center.refresh()
        #expect(center.visibleBinaryEntries.map(\.id) == ["pairing.1.0.6"])
        #expect(center.unseenPages.map(\.id) == ["pairing.1.0.6"])
    }

    @Test func remoteEntryChannelsCanAlsoNarrowTeamBuilds() async {
        // The remote override REPLACES the compiled-in declaration, so an
        // operator can retract an entry from a single lane remotely.
        let payload = #"""
        {
          "visibleEntryIds": ["pairing.1.0.6"],
          "entryChannels": { "pairing.1.0.6": ["prod"] },
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
