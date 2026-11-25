import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

@MainActor
@Suite struct InstallWatchdogIntegrationTests {
    private func updateAvailable(_ version: String = "0.64.16") -> UpdateState {
        let item = SUAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]) ?? SUAppcastItem.empty()
        return .updateAvailable(.init(appcastItem: item, reply: { _ in }))
    }

    @Test func mapsSparkleStatesToInstallPhases() {
        let states: [(UpdateState, UpdateLifecyclePhase)] = [
            (.idle, .idle),
            (.permissionRequest(.init(request: SPUUpdatePermissionRequest(systemProfile: []), reply: { _ in })), .permissionRequest),
            (.preparingCheck(.init(cancel: {})), .preparingCheck),
            (.checking(.init(cancel: {})), .checking),
            (updateAvailable(), .updateAvailable),
            (.notFound(.init(acknowledgement: {})), .notFound),
            (.error(.init(error: NSError(domain: "t", code: 1), retry: {}, dismiss: {})), .error),
            (.startingDownload, .startingDownload),
            (.downloading(.init(cancel: {}, expectedLength: 100, progress: 10)), .downloading),
            (.extracting(.init(progress: 0.5)), .extracting),
            (.installing(.init(retryTerminatingApplication: {}, dismiss: {})), .installing),
        ]
        #expect(Set(states.map { $0.1 }) == Set(UpdateLifecyclePhase.allCases))
        for (state, expectedPhase) in states {
            #expect(state.lifecyclePhase == expectedPhase)
        }
    }

    /// The watchdog error offers the direct-download recovery (the in-app path just proved it
    /// can't start), while the transient "updater not ready" error does not.
    @Test func watchdogErrorOffersManualDownload() {
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let notReady = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.updaterNotReadyCode)
        let recovery = UpdateManualDownloadRecovery()
        #expect(recovery.url(for: didNotStart) != nil)
        #expect(recovery.url(for: notReady) == nil)
    }

    /// The manual-download recovery routes to the failing build's own channel: a nightly feed
    /// gets the nightly DMG, everything else the latest stable DMG. A NIGHTLY user must
    /// never be pointed at a stable download as the fix for a nightly install failure.
    @Test func manualDownloadRoutesToTheActiveChannel() throws {
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let nightlyFeed = "https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast.xml"
        let recovery = UpdateManualDownloadRecovery(hostArchitecture: .arm64)

        let nightlyURL = try #require(recovery.url(for: didNotStart, feedURLString: nightlyFeed))
        #expect(nightlyURL.absoluteString.hasSuffix("/releases/download/nightly/cmux-nightly-macos-arm64.dmg"))
        #expect(!nightlyURL.absoluteString.contains("latest/download"))

        // A cmux-next NIGHTLY recovers to its own track's DMG, never main's NIGHTLY DMG: the
        // cmux.com route that resolves the update feed's newest DMG. The rolling release asset
        // can trail the feed, and installing the build before the offered one repeats the failure.
        let nextURL = try #require(recovery.url(for: didNotStart,
                                                feedURLString: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"))
        #expect(nextURL.absoluteString == "https://cmux.com/api/download/next")

        let stableURL = try #require(recovery.url(for: didNotStart, feedURLString: "https://cmux.com/appcast.xml"))
        #expect(stableURL.absoluteString.contains("latest/download"))

        // Sparkle's own install failures route by channel the same way.
        let sparkleInstallFailure = NSError(domain: SUSparkleErrorDomain, code: 4005)
        let sparkleNightlyURL = try #require(recovery.url(for: sparkleInstallFailure, feedURLString: nightlyFeed))
        #expect(sparkleNightlyURL.absoluteString.hasSuffix("/releases/download/nightly/cmux-nightly-macos-arm64.dmg"))

        // An Intel Mac is offered the Intel nightly DMG.
        let intelRecovery = UpdateManualDownloadRecovery(hostArchitecture: .x86_64)
        let intelURL = try #require(intelRecovery.url(for: didNotStart, feedURLString: nightlyFeed))
        #expect(intelURL.absoluteString.hasSuffix("/releases/download/nightly/cmux-nightly-macos-x86_64.dmg"))
    }

    /// An RC build recovers to the RC DMG for its architecture, never the stable one.
    @Test func manualDownloadRoutesRCFeedToTheRCDMG() throws {
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let rcFeed = "https://files.cmux.com/rc/appcast-arm64.xml"

        let armURL = try #require(UpdateManualDownloadRecovery(hostArchitecture: .arm64).url(for: didNotStart, feedURLString: rcFeed))
        #expect(armURL.absoluteString == "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-arm64.dmg")

        let sparkleInstallFailure = NSError(domain: SUSparkleErrorDomain, code: 4005)
        let intelURL = try #require(UpdateManualDownloadRecovery(hostArchitecture: .x86_64).url(for: sparkleInstallFailure, feedURLString: rcFeed))
        #expect(intelURL.absoluteString == "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-x86_64.dmg")
        #expect(!intelURL.absoluteString.contains("latest/download"))
        #expect(!intelURL.absoluteString.contains("/nightly/"))
    }

    /// The watchdog can fire before Sparkle asks its delegate for a feed URL; in that passive path
    /// the driver still needs to recover the build's appcast channel so NIGHTLY installs offer the
    /// nightly DMG instead of downgrading to stable.
    @Test func unresolvedDelegateFeedStillRoutesWatchdogRecoveryToNightly() throws {
        let nightlyFeed = "https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast.xml"
        let driver = UpdateDriver(
            model: UpdateStateModel(),
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false,
            infoFeedURLProvider: { nightlyFeed }
        )

        // The passive path resolves the build's own nightly channel, for this machine's architecture.
        let resolvedFeed = try #require(driver.resolvedFeedURLString())
        #expect(resolvedFeed.hasPrefix("https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast-"))
        #expect(resolvedFeed.hasSuffix("\(UpdateHostArchitecture.current.rawValue).xml"))

        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let recoveryURL = try #require(UpdateManualDownloadRecovery(hostArchitecture: .arm64).url(
            for: didNotStart,
            feedURLString: driver.resolvedFeedURLString()
        ))
        #expect(recoveryURL.absoluteString == "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-arm64.dmg")

        let recordedFeed = "https://example.com/other/appcast.xml"
        driver.recordFeedURLString(recordedFeed, usedFallback: false)
        #expect(driver.resolvedFeedURLString() == recordedFeed)
    }

    /// An unrecognized cmux.update code renders the generic failure title instead of silently
    /// masquerading as "Updater Not Ready".
    @Test func unknownCmuxUpdateCodeFallsBackToGenericTitle() {
        let unknown = NSError(domain: UpdateStateModel.updateErrorDomain, code: 999)
        #expect(UpdateStateModel.userFacingErrorTitle(for: unknown) == "Update Failed")
    }

    /// The watchdog error renders with its own copy, not the generic "Update Failed" catch-all.
    @Test func watchdogErrorRendersDedicatedCopy() {
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.installDidNotStartCode,
            userInfo: [NSLocalizedDescriptionKey: "cmux couldn’t start the update. Check your internet connection and try again."]
        )
        let title = UpdateStateModel.userFacingErrorTitle(for: error)
        let message = UpdateStateModel.userFacingErrorMessage(for: error)
        #expect(title == "Update Didn’t Start")
        #expect(message.contains("couldn’t start the update"))
        #expect(title != "Update Failed")
    }
}
