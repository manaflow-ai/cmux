import Foundation
import Testing
@testable import CmuxUpdater

/// `SPUUserUpdateChoice` raw values (Sparkle/SPUUserUpdateState.h: Skip, Install, Dismiss).
private let sparkleSkip = 0
private let sparkleInstall = 1
private let sparkleDismiss = 2

/// The `SPUUpdaterDelegate` optional methods the pre-seam `UpdateDriver` answered
/// (Sparkle/SPUUpdaterDelegate.h). Sparkle checks each with `respondsToSelector:`.
private let answeredDelegateSelectors = [
    "updaterShouldPromptForPermissionToCheckForUpdates:",
    "feedURLStringForUpdater:",
    "allowedChannelsForUpdater:",
    "updater:willInstallUpdate:",
    "updater:willScheduleUpdateCheckAfterDelay:",
    "updaterWillNotScheduleUpdateCheck:",
    "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
    "updater:didFinishLoadingAppcast:",
    "updater:didFindValidUpdate:",
    "updaterDidNotFindUpdate:error:",
    "updater:didFinishUpdateCycleForUpdateCheck:error:",
    "updater:userDidMakeChoice:forUpdate:state:",
    "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
    "updaterWillRelaunchApplication:",
]

/// Every `SPUUserDriver` method the driver answered: the required ones and `showUpdateInFocus`
/// (Sparkle/SPUUserDriver.h).
private let answeredUserDriverSelectors = [
    "showUpdatePermissionRequest:reply:",
    "showUserInitiatedUpdateCheckWithCancellation:",
    "showUpdateFoundWithAppcastItem:state:reply:",
    "showUpdateReleaseNotesWithDownloadData:",
    "showUpdateReleaseNotesFailedToDownloadWithError:",
    "showUpdateNotFoundWithError:acknowledgement:",
    "showUpdaterError:acknowledgement:",
    "showDownloadInitiatedWithCancellation:",
    "showDownloadDidReceiveExpectedContentLength:",
    "showDownloadDidReceiveDataOfLength:",
    "showDownloadDidStartExtractingUpdate",
    "showExtractionReceivedProgress:",
    "showReadyToInstallAndRelaunch:",
    "showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:",
    "showUpdateInstalledAndRelaunched:acknowledgement:",
    "dismissUpdateInstallation",
    "showUpdateInFocus",
]

/// Optional Sparkle methods the driver never answered: implementing one changes what Sparkle
/// does (a check veto, a relaunch policy, a deprecated fallback path).
private let unansweredSelectors = [
    "updater:mayPerformUpdateCheck:error:",
    "updaterMayCheckForUpdates:",
    "updater:shouldProceedWithUpdate:updateCheck:error:",
    "bestValidUpdateInAppcast:forUpdater:",
    "updaterDidNotFindUpdate:",
    "feedParametersForUpdater:sendingSystemProfile:",
    "allowedSystemProfileKeysForUpdater:",
    "updater:shouldDownloadReleaseNotesForUpdate:",
    "updater:willDownloadUpdate:withRequest:",
    "updater:didDownloadUpdate:",
    "updater:failedToDownloadUpdate:error:",
    "userDidCancelDownload:",
    "updater:willExtractUpdate:",
    "updater:didExtractUpdate:",
    "updaterShouldRelaunchApplication:",
    "versionComparatorForUpdater:",
    "decryptionPasswordForUpdater:",
    "updater:didAbortWithError:",
    "updater:userDidSkipThisVersion:",
    "showUpdateNotFoundWithAcknowledgement:",
    "showUpdateInstallationDidFinishWithAcknowledgement:",
    "dismissUserInitiatedUpdateCheck",
    "showInstallingUpdate",
    "showSendingTerminationSignal",
    "showInstallingUpdateWithApplicationTerminated:",
]

/// The Sparkle seam (`SparkleSeam.swift`) translates Sparkle's callbacks into ``UpdateDriver``
/// calls and the driver's answers back into Sparkle's values. These tests drive the bridge the
/// way Sparkle does and read what Sparkle would receive, with no Sparkle import: the reply
/// closures get Sparkle's own `SPUUserUpdateChoice`, recorded by raw value and compared with the
/// values Sparkle's headers declare.
@MainActor
@Suite struct SparkleSeamTests {
    private let model = UpdateStateModel()

    /// The raw values of the `SPUUserUpdateChoice` replies Sparkle received.
    @MainActor
    private final class SparkleReplies {
        var rawValues: [Int] = []
    }

    /// Records the update-cycle kinds the driver forwards to its lifecycle owner.
    @MainActor
    private final class CycleSpy: UpdateDriverEventDelegate {
        var checks: [UpdateCheckKind] = []

        func updateDriverDidFinishCycle(_ updateCheck: UpdateCheckKind, error: NSError?) { checks.append(updateCheck) }
        func updateDriverUserDidCancelCheck() {}
        func updateDriverUserDidDismissPrompt() {}
    }

    /// An ``UpdateLogging`` that hands every line to an `AsyncStream`, so a test reads the log.
    private struct StreamUpdateLog: UpdateLogging {
        let continuation: AsyncStream<String>.Continuation

        func append(_ message: String) { continuation.yield(message) }
        func logPath() -> String { "/dev/null" }
    }

    private func makeDriver(log: any UpdateLogging = NoopUpdateLog()) -> UpdateDriver {
        UpdateDriver(model: model, log: log, clock: TestDeadlineClock())
    }

    private func makeItem(_ version: String) throws -> UpdateAppcastItem {
        try #require(UpdateAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]))
    }

    /// Sparkle calls only what the bridge answers, so the bridge answers exactly the selectors
    /// the driver did before the seam.
    @Test func bridgeAnswersTheSelectorsTheDriverAnswered() {
        let bridge = SparkleDriverBridge(driver: makeDriver())
        for selector in answeredDelegateSelectors + answeredUserDriverSelectors {
            #expect(bridge.responds(to: NSSelectorFromString(selector)), "Sparkle no longer calls \(selector)")
        }
        for selector in unansweredSelectors {
            #expect(!bridge.responds(to: NSSelectorFromString(selector)), "Sparkle now calls \(selector)")
        }
    }

    @Test func readyReplyReachesSparkleAsInstall() {
        let driver = makeDriver()
        let bridge = SparkleDriverBridge(driver: driver)
        let replies = SparkleReplies()

        bridge.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { replies.rawValues.append(choice.rawValue) }
        })

        #expect(replies.rawValues == [sparkleInstall])
    }

    /// A staged background update's installer is cancelled with Sparkle's Skip, which records
    /// no skipped version (not Dismiss, which would leave the installer to run on quit).
    @Test func cancelledStagedInstallReachesSparkleAsSkip() {
        let driver = makeDriver()
        driver.installsInBackground = true
        let bridge = SparkleDriverBridge(driver: driver)
        let replies = SparkleReplies()

        bridge.showReady(toInstallAndRelaunch: { choice in
            MainActor.assumeIsolated { replies.rawValues.append(choice.rawValue) }
        })
        #expect(replies.rawValues.isEmpty, "a background install holds Sparkle's reply until the host acts")
        #expect(driver.cancelStaged())

        #expect(replies.rawValues == [sparkleSkip])
    }

    /// The person's answer to an update prompt reaches Sparkle as Sparkle's own choice.
    @Test(arguments: [
        (UpdateChoice.skip, sparkleSkip),
        (UpdateChoice.install, sparkleInstall),
        (UpdateChoice.dismiss, sparkleDismiss),
    ])
    func promptAnswerReachesSparkle(choice: UpdateChoice, sparkleRawValue: Int) throws {
        let bridge = SparkleDriverBridge(driver: makeDriver())
        let replies = SparkleReplies()
        let item = try makeItem("0.64.17")

        bridge.forwardUpdateFound(item, reply: { choice in
            MainActor.assumeIsolated { replies.rawValues.append(choice.rawValue) }
        })
        guard case .updateAvailable(let available) = model.state else {
            Issue.record("the bridge must offer a found update; state=\(model.state)")
            return
        }
        #expect(replies.rawValues.isEmpty, "the prompt waits for the person")
        available.reply(choice)

        #expect(replies.rawValues == [sparkleRawValue])
    }

    /// Sparkle's permission request is answered with scheduled checks on and no system profile.
    @Test func permissionRequestReachesSparkleAsChecksWithoutProfile() async {
        let bridge = SparkleDriverBridge(driver: makeDriver())

        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<[Bool], Never>) in
            bridge.forwardPermissionRequest(reply: { response in
                continuation.resume(returning: [response.automaticUpdateChecks, response.sendSystemProfile])
            })
        }

        #expect(answer == [true, false])
    }

    /// Each `SPUUpdateCheck` Sparkle ends a cycle with reaches the lifecycle owner as its kind.
    @Test func finishedCycleReachesTheOwnerAsItsCheckKind() {
        let driver = makeDriver()
        let spy = CycleSpy()
        driver.eventDelegate = spy
        let bridge = SparkleDriverBridge(driver: driver)

        bridge.forwardUpdateCycleFinished(.updates, error: nil)
        bridge.forwardUpdateCycleFinished(.updatesInBackground, error: nil)
        bridge.forwardUpdateCycleFinished(.updateInformation, error: nil)

        #expect(spy.checks == [.updates, .updatesInBackground, .updateInformation])
    }

    /// Sparkle's no-update error is read by the string values of its `userInfo` keys
    /// (Sparkle/SUConstants.m: `SUNoUpdateFoundReason`, `SPUNoUpdateUserInitiated`).
    @Test(arguments: [
        (1, true, "no update found (reason=onLatestVersion, userInitiated=true)"),
        (2, false, "no update found (reason=onNewerThanLatestVersion, userInitiated=false)"),
        (nil, nil, "no update found (reason=unknown, userInitiated=false)"),
    ] as [(Int?, Bool?, String)])
    func noUpdateErrorIsReadFromSparklesKeys(reason: Int?, userInitiated: Bool?, expected: String) async {
        var userInfo: [String: Any] = [:]
        if let reason { userInfo["SUNoUpdateFoundReason"] = NSNumber(value: reason) }
        if let userInitiated { userInfo["SPUNoUpdateUserInitiated"] = NSNumber(value: userInitiated) }
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let driver = makeDriver(log: StreamUpdateLog(continuation: continuation))

        driver.handleDidNotFindUpdate(NSError(domain: "SUSparkleErrorDomain", code: 1001, userInfo: userInfo))
        continuation.finish()

        var logged: [String] = []
        for await line in lines { logged.append(line) }
        #expect(logged.contains(expected), "logged: \(logged)")
    }

    @Test func userCheckReachesTheDriverThroughTheBridge() {
        let driver = makeDriver()
        let bridge = SparkleDriverBridge(driver: driver)

        bridge.showUserInitiatedUpdateCheck(cancellation: {})

        guard case .checking = model.state else {
            Issue.record("the bridge must forward a user check to the driver; state=\(model.state)")
            return
        }
    }

    @Test func appcastItemReadsSparklesValues() throws {
        let item = try #require(UpdateAppcastItem(dictionary: [
            "title": "cmux 0.64.17",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "description": "Fixes.",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "6417",
                "sparkle:shortVersionString": "0.64.17",
            ],
        ]))
        #expect(item.versionString == "6417")
        #expect(item.displayVersionString == "0.64.17")
        #expect(item.contentLength == 1024)
        #expect(item.fileURL?.absoluteString == "https://example.com/cmux.zip")
        #expect(item.itemDescription == "Fixes.")
        #expect(item.date != nil)
        #expect(!item.listsDeltas)
    }

    @Test func versionComparatorUsesSparklesOrder() {
        let comparator = SparkleVersionComparator()
        #expect(comparator.compare("1.0.9", "1.0.10") == .orderedAscending)
        #expect(comparator.compare("200", "199") == .orderedDescending)
        #expect(comparator.compare("1.2", "1.2") == .orderedSame)
    }
}
