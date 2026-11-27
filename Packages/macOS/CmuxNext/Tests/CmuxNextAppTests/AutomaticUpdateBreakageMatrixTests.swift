import CmuxNextTestSupport
@testable import CmuxNextUpdater
@testable import CmuxUpdater
import Foundation
@preconcurrency import Sparkle
import Testing

/// One deterministic matrix exercises the bundle, feed, policy, transfer and relaunch failure
/// boundaries that have repeatedly made an update look enabled while it could not complete.
/// Each row is independent so Swift Testing can run the cases in parallel without sharing defaults.
@MainActor struct AutomaticUpdateBreakageMatrixTests {
    enum Scenario: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case missingFeedMetadata
        case malformedFeedMetadata
        case stableFeed
        case nightlyArm64Feed
        case nightlyX8664Feed
        case releaseCandidateFeed
        case nightlyNextFeed
        case missingPublicKey
        case managedDisable
        case developmentBundle
        case legacyAutomaticInstall
        case explicitAutomaticInstallOptOut
        case classicSparklePolicy
        case nextAppOwnedPolicy
        case corruptDownloadRecovery
        case invalidSignatureRecovery
        case offlineThenResume
        case newerStagedItemReplacesOlder
        case liveSessionsBlockRelaunch
        case pausedThenResumed

        var testDescription: String { rawValue }
    }

    private static let stableFeed = "https://files.cmux.com/stable/appcast.xml"
    private static let nightlyFeed = "https://files.cmux.com/nightly/appcast.xml"
    private static let nextFeed = "https://files-next.cmux.com/nightly-next/appcast.xml"

    private static func identity(bundleID: String = "com.cmuxterm.app",
                                 feed: String? = stableFeed,
                                 hasPublicKey: Bool = true) -> UpdateBuildIdentity {
        UpdateBuildIdentity(bundleIdentifier: bundleID, shortVersion: "1.0.0", build: "100",
                            minimumSystemVersion: nil, infoFeedURL: feed, hasPublicKey: hasPublicKey)
    }

    private static func updater(identity: UpdateBuildIdentity,
                                paused: Bool = false,
                                defaults: UserDefaults? = nil) -> UpdaterService {
        let suite = "AutomaticUpdateBreakageMatrixTests.\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(testSuiteName: suite)!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false,
                                     pausesAutomaticUpdates: paused)
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    private static func freshDefaults() -> (UserDefaults, String) {
        let suite = "AutomaticUpdateBreakageMatrixTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test(arguments: Scenario.allCases)
    func everyBundleAndUpdateBreakageHasARecoveryPath(_ scenario: Scenario) throws {
        switch scenario {
        case .missingFeedMetadata:
            let result = Self.identity(feed: nil).feed(architecture: .arm64)
            #expect(result.usedFallback)
            #expect(result.channel == .stable)

        case .malformedFeedMetadata:
            let result = UpdateFeedResolver(fallbackFeedURL: Self.stableFeed)
                .resolve(infoFeedURL: "https:///missing-host/appcast.xml")
            #expect(result.usedFallback)
            #expect(result.url == Self.stableFeed)

        case .stableFeed:
            let identity = Self.identity()
            #expect(identity.track == .stable)
            #expect(identity.feed(architecture: .x86_64).url == Self.stableFeed)

        case .nightlyArm64Feed:
            let result = UpdateFeedResolver(hostArchitecture: .arm64).resolve(infoFeedURL: Self.nightlyFeed)
            #expect(result.channel == .nightly)
            #expect(result.url.hasSuffix("appcast-arm64.xml"))

        case .nightlyX8664Feed:
            let result = UpdateFeedResolver(hostArchitecture: .x86_64).resolve(infoFeedURL: Self.nightlyFeed)
            #expect(result.channel == .nightly)
            #expect(result.url.hasSuffix("appcast-x86_64.xml"))

        case .releaseCandidateFeed:
            let identity = Self.identity(feed: "https://files.cmux.com/rc/appcast.xml")
            #expect(identity.track == .rc)
            #expect(identity.feed(architecture: .arm64).url.hasSuffix("appcast-arm64.xml"))

        case .nightlyNextFeed:
            let identity = Self.identity(bundleID: "com.cmuxterm.app.nightly.cmux-next", feed: Self.nextFeed)
            #expect(identity.track == .nightlyNext)
            #expect(identity.feed(architecture: .arm64).url.hasSuffix("appcast-arm64.xml"))
            #expect(identity.feed(architecture: .arm64).channel.allowedSparkleChannels.contains("cmux-next"))

        case .missingPublicKey:
            #expect(Self.identity(hasPublicKey: false).sparkleDisabledReason(managedPolicyDisablesUpdates: false)
                    == .missingPublicKey)

        case .managedDisable:
            #expect(Self.identity().sparkleDisabledReason(managedPolicyDisablesUpdates: true) == .managedPolicy)

        case .developmentBundle:
            let identity = Self.identity(bundleID: "com.cmuxterm.app.debug.matrix")
            #expect(identity.track == .development)
            #expect(identity.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .developmentBuild)

        case .legacyAutomaticInstall:
            let (defaults, suite) = Self.freshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
            UpdateSettings().apply(to: defaults)
            #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
            #expect(defaults.bool(forKey: UpdateSettings.automaticInstallMigrationKey))

        case .explicitAutomaticInstallOptOut:
            let (defaults, suite) = Self.freshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            UpdateSettings().apply(to: defaults)
            defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
            UpdateSettings().apply(to: defaults)
            #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        case .classicSparklePolicy:
            for track in UpdateTrack.allCases {
                #expect(track.downloadsAutomaticallyByDefault, "\(track) lost the automatic-download default")
            }
            let updater = Self.updater(identity: Self.identity())
            updater.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true)
            updater.networkPending = false
            updater.network = (constrained: false, expensive: false)
            updater.applyDownloadPolicy()
            #expect(updater.status.automaticDownloads,
                    "the classic app-owned download policy did not enable background downloads")

        case .nextAppOwnedPolicy:
            let (defaults, suite) = Self.freshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)
            let updater = Self.updater(identity: Self.identity(bundleID: "com.cmuxterm.app.nightly.cmux-next",
                                                               feed: Self.nextFeed), defaults: defaults)
            updater.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true)
            updater.networkPending = false
            updater.network = (constrained: false, expensive: false)
            updater.applyDownloadPolicy()
            #expect(updater.automaticUpdates)
            #expect(updater.downloadsFoundUpdates)
            #expect(updater.status.automaticDownloads)
            #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey),
                    "cmux NEXT changed the shared Sparkle preference while enabling its own policy")

        case .corruptDownloadRecovery:
            let error = NSError(domain: SUSparkleErrorDomain, code: 2001)
            #expect(UpdateManualDownloadRecovery().url(for: error, feedURLString: Self.nightlyFeed) != nil)

        case .invalidSignatureRecovery:
            let error = NSError(domain: SUSparkleErrorDomain, code: 3001)
            #expect(UpdateManualDownloadRecovery().url(for: error, feedURLString: Self.nightlyFeed) == nil)

        case .offlineThenResume:
            let updater = Self.updater(identity: Self.identity(bundleID: "com.cmuxterm.app.nightly.cmux-next",
                                                               feed: Self.nextFeed))
            updater.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true,
                              metered: .deferLowData)
            updater.network = (constrained: true, expensive: false)
            updater.downloadSetting = (true, .deferLowData)
            updater.applyDownloadPolicy()
            #expect(!updater.downloadsFoundUpdates)
            updater.network = (constrained: false, expensive: false)
            updater.applyDownloadPolicy()
            #expect(updater.downloadsFoundUpdates)

        case .newerStagedItemReplacesOlder:
            let updater = Self.updater(identity: Self.identity(bundleID: "com.cmuxterm.app.nightly.cmux-next",
                                                               feed: Self.nextFeed))
            updater.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true)
            updater.debugIndicatorPhase = .ready(version: "1.0.1")
            updater.debugIndicatorPhase = .ready(version: "1.0.2")
            #expect(updater.readyCard?.detail?.contains("1.0.2") == true)

        case .liveSessionsBlockRelaunch:
            let blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 1)
            #expect(!blockers.isEmpty)
            #expect(!blockers.forUserInstall.isEmpty)

        case .pausedThenResumed:
            let (defaults, suite) = Self.freshDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let paused = Self.updater(identity: Self.identity(bundleID: "com.cmuxterm.app.nightly"),
                                      paused: true, defaults: defaults)
            paused.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true)
            #expect(!paused.automaticUpdates)
            let resumed = Self.updater(identity: Self.identity(bundleID: "com.cmuxterm.app.nightly"),
                                       paused: false, defaults: defaults)
            resumed.configure(checkAutomatically: true, checkInterval: 900, downloadAutomatically: true)
            #expect(resumed.automaticUpdates)
        }
    }
}
