import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

@MainActor
@Suite struct UpdaterServiceTests {
    private func defaults() -> UserDefaults {
        let name = "cmux-next-updater-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func service(_ identity: UpdateBuildIdentity, data: Data?, managed: Bool = false, sparkle: Bool = false) -> (UpdaterService, FixtureFetcher) {
        let fetcher = FixtureFetcher(data)
        let service = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { managed },
                                     prober: UpdateProber(fetcher: fetcher, architecture: .arm64),
                                     defaults: defaults(), enableSparkle: sparkle)
        return (service, fetcher)
    }

    @Test func devBuildCheckProbesTheRealFeedShapeAndNeverBuildsSparkle() async {
        let feed = AppcastFixtures.feed(AppcastFixtures.item("106", short: "0.64.25", minimum: "14.0"))
        let (service, fetcher) = service(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.updtr", build: "106"), data: feed, sparkle: true)
        var presented = 0
        service.presentUpdateUI = { presented += 1 }
        #expect(service.controller == nil)
        #expect(service.disabledReason == .developmentBuild)
        let failure = await service.checkForUpdates()?.value
        #expect(failure == nil)
        // Nothing asks: the result is a note beside the rail circle.
        #expect(presented == 0)
        #expect(service.indicatorPhase == .note(UpdaterStrings.upToDate, isError: false))
        service.dismissIndicatorNote()
        #expect(service.indicatorPhase == .hidden)
        #expect(fetcher.requested.count == 1)
        #expect(service.lastProbe?.outcome == .upToDate(latest: AppcastItem(version: "106", displayVersion: "0.64.25",
            title: "0.64.25", minimumSystemVersion: SystemVersion("14.0"),
            releaseNotesURL: URL(string: "https://github.com/manaflow-ai/cmux/releases/tag/v0.64.25"),
            downloadURL: URL(string: "https://github.com/manaflow-ai/cmux/releases/download/v106/cmux-macos.dmg"))))
        let status = service.status
        #expect(status.track == .development)
        #expect(status.sparkleDisabledReason == .developmentBuild)
        #expect(status.automaticChecks == false)
        #expect(status.phase == .idle)
        #expect(status.lastProbe != nil)
    }

    @Test func probeFailureIsTyped() async {
        let (service, _) = service(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.t"), data: nil)
        let failure = await service.probe().value
        #expect(failure == "offline")
        #expect(service.lastProbeError == "offline")
        #expect(!service.isProbing)
    }

    @Test func managedPolicyNeverTouchesTheFeed() async {
        let (service, fetcher) = service(AppcastFixtures.identity(), data: AppcastFixtures.feed(), managed: true)
        var presented = 0
        service.presentUpdateUI = { presented += 1 }
        #expect(service.checkForUpdates() == nil)
        // The managed explanation is the one check result that still opens the sheet.
        #expect(presented == 1)
        #expect(fetcher.requested.isEmpty)
        #expect(service.disabledReason == .managedPolicy)
        #expect(throws: UpdaterUnavailable.self) { try service.installAvailableUpdate() }
        #expect(throws: UpdaterUnavailable.self) { try service.switchChannel(to: .nightly) }
    }

    @Test func releaseBuildBuildsTheSparkleDriverAndRegistersLegacyDefaults() {
        let defaults = defaults()
        let service = UpdaterService(identity: AppcastFixtures.identity(), policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: FixtureFetcher(nil)), defaults: defaults)
        #expect(service.controller != nil)
        #expect(service.disabledReason == nil)
        // The legacy app's settings keys, with its defaults (hourly, checks on).
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        #expect(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey) == 3600)
        #expect(service.status.automaticChecks)
        #expect(!service.status.automaticDownloads)
        // cmux-next downloads in the background on its own updater only:
        // SUAutomaticallyUpdate stays off for the legacy app sharing the domain.
        #expect(service.controller?.installsUpdatesInBackground == true)
        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }

    @Test func channelSwitchOnlyToTheCounterpart() {
        let (dev, _) = service(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.t"), data: nil)
        #expect(throws: UpdaterUnavailable.self) { try dev.switchChannel(to: .stable) }
        let (stable, _) = service(AppcastFixtures.identity(), data: nil)
        #expect(throws: UpdaterUnavailable.self) { try stable.switchChannel(to: .stable) }
    }

    @Test func relaunchIsNeverBlocked() {
        let (service, _) = service(AppcastFixtures.identity(), data: nil)
        #expect(service.updaterRelaunchBlockers() == .empty)
    }
}

@MainActor
@Suite struct UpdateSheetContentTests {
    private func result(_ outcome: UpdateProbeOutcome, track: UpdateTrack = .development) -> UpdateProbeResult {
        UpdateProbeResult(track: track, feedURL: "https://example.invalid/appcast.xml", currentVersion: "0.64.25", currentBuild: "106",
                          system: SystemVersion(major: 15, minor: 6), itemCount: 1, outcome: outcome, checkedAt: Date())
    }

    @Test func probeStates() {
        #expect(UpdateSheetContent.probe(result: nil, error: nil, probing: true, disabledReason: .developmentBuild).progress == .indeterminate)
        let failed = UpdateSheetContent.probe(result: nil, error: "offline", probing: false, disabledReason: .developmentBuild)
        #expect(failed.detail == "offline")
        #expect(failed.buttons == [.done, .retry])
        let managed = UpdateSheetContent.probe(result: nil, error: nil, probing: false, disabledReason: .managedPolicy)
        #expect(managed.buttons == [.done])
        #expect(managed.symbol == "lock")
    }

    @Test func devBuildNeverOffersInstall() {
        let item = AppcastItem(version: "107", displayVersion: "1.0.0", releaseNotesURL: URL(string: "https://example.invalid/notes"))
        let content = UpdateSheetContent.probe(result: result(.updateAvailable(item)), error: nil, probing: false, disabledReason: .developmentBuild)
        #expect(content.buttons == [.done])
        #expect(!content.buttons.contains(.install))
        #expect(content.link == .releaseNotes(URL(string: "https://example.invalid/notes")!))
        #expect(content.title.contains("1.0.0"))
    }

    @Test func olderMacExplainsTheFloor() {
        let item = AppcastItem(version: "107", displayVersion: "1.0.0", minimumSystemVersion: SystemVersion("26.0"))
        let content = UpdateSheetContent.probe(result: result(.requiresNewerSystem(item, required: SystemVersion(major: 26))),
                                               error: nil, probing: false, disabledReason: .developmentBuild)
        #expect(content.title.contains("26.0"))
        #expect(content.detail?.contains("15.6") == true)
        #expect(content.buttons == [.done])
    }

    @Test func sparklePhases() {
        let identity = AppcastFixtures.identity()
        #expect(UpdateSheetContent.sparkle(.idle, current: identity) == nil)
        #expect(UpdateSheetContent.sparkle(.checking(.init(cancel: {})), current: identity)?.buttons == [.cancel])
        #expect(UpdateSheetContent.sparkle(.notFound(.init(acknowledgement: {})), current: identity)?.buttons == [.done])
        let download = UpdateSheetContent.sparkle(.downloading(.init(cancel: {}, expectedLength: 200, progress: 50)), current: identity)
        #expect(download?.progress == .fraction(0.25))
        let error = UpdateSheetContent.sparkle(.error(.init(error: NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]),
                                                            retry: {}, dismiss: {})), current: identity)
        #expect(error?.detail == "boom")
        #expect(error?.buttons == [.done, .retry])
        let ready = UpdateSheetContent.sparkle(.installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {})), current: identity)
        #expect(ready?.buttons == [.later, .relaunch])
    }

    /// With the window rail off there is no circle, so a check falls back to the sheet.
    @Test func checksOpenTheSheetWhenThereIsNoCircle() async {
        let feed = AppcastFixtures.feed(AppcastFixtures.item("106", short: "0.64.25", minimum: "14.0"))
        let (updater, _) = service(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.updtr", build: "106"), data: feed)
        var presented = 0
        updater.presentUpdateUI = { presented += 1 }
        updater.showsIndicator = { false }
        _ = await updater.checkForUpdates()?.value
        #expect(presented == 1)
    }

    /// A note's timeout leaves the state alone while the sheet shows its details.
    @Test func aNoteOutlivesItsTimeoutWhileTheSheetIsOpen() async {
        let (updater, _) = service(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.t"), data: nil)
        _ = await updater.checkForUpdates()?.value
        #expect(updater.indicatorPhase == .note(UpdaterStrings.checkFailed, isError: true))
        updater.isSheetPresented = { true }
        updater.dismissIndicatorNote()
        #expect(updater.indicatorPhase == .note(UpdaterStrings.checkFailed, isError: true))
        updater.isSheetPresented = { false }
        updater.dismissIndicatorNote()
        #expect(updater.indicatorPhase == .hidden)
    }
}
