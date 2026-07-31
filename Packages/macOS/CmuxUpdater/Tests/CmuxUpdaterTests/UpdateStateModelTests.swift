import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

@MainActor
@Suite struct UpdateStateModelTests {
    private func makeItem(_ version: String) -> SUAppcastItem {
        SUAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]) ?? SUAppcastItem.empty()
    }

    /// Regression for #8368: `updaterDidNotFindUpdate` is shared by background probes and
    /// foreground checks. Clearing passive detection must never answer or remove an unrelated
    /// foreground prompt.
    @Test func clearingDetectedUpdateDoesNotDismissForegroundPrompt() {
        let model = UpdateStateModel()
        let detected = makeItem("0.64.15")
        let foreground = makeItem("0.64.16")
        let reply = ChoiceBox()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        model.recordDetectedUpdate(detected)
        model.setState(.updateAvailable(.init(appcastItem: foreground, reply: { choice in
            MainActor.assumeIsolated { reply.choice = choice }
        })))

        driver.handleDidNotFindUpdate(NSError(domain: SUSparkleErrorDomain, code: 1001))

        #expect(model.detectedUpdateItem == nil)
        #expect(model.detectedUpdateVersion == nil)
        #expect(reply.choice == nil)
        guard case .updateAvailable(let available) = model.state else {
            Issue.record("background no-update result dismissed foreground state: \(model.state)")
            return
        }
        #expect(available.appcastItem.displayVersionString == "0.64.16")
    }

    @Test func setStateEmitsOnStateChangesStream() async {
        let model = UpdateStateModel()
        var iterator = model.stateChanges().makeAsyncIterator()

        model.setState(.checking(.init(cancel: {})))
        let signal: Void? = await iterator.next()

        #expect(signal != nil)
        #expect(model.state == .checking(.init(cancel: {})))
    }

    @Test func setOverrideStateAlsoEmits() async {
        let model = UpdateStateModel()
        var iterator = model.stateChanges().makeAsyncIterator()

        model.setOverrideState(.notFound(.init(acknowledgement: {})))
        let signal: Void? = await iterator.next()

        #expect(signal != nil)
        #expect(model.overrideState == .notFound(.init(acknowledgement: {})))
    }

    @Test func progressStateChangesCoalesceBeforeDrain() {
        let model = UpdateStateModel()

        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 10)))
        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 50)))
        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 90)))

        let changes = model.drainPendingChanges()
        #expect(changes.count == 1)
        guard case .downloading(let download) = changes.first?.state else {
            Issue.record("expected latest downloading state")
            return
        }
        #expect(download.progress == 90)
    }

    @Test func controlStateChangesStayOrderedBeforeDrain() {
        let model = UpdateStateModel()

        model.setState(.idle)
        model.setState(.checking(.init(cancel: {})))
        model.setState(.idle)

        let changes = model.drainPendingChanges()
        #expect(changes.count == 3)
        #expect(changes.map(\.state) == [.idle, .checking(.init(cancel: {})), .idle])
    }

    @Test func effectiveStatePrefersOverride() {
        let model = UpdateStateModel()
        model.setState(.idle)
        model.setOverrideState(.checking(.init(cancel: {})))
        #expect(model.effectiveState == .checking(.init(cancel: {})))
        #expect(model.showsPill)
    }

    @Test func idleWithNoDetectedUpdateHidesPill() {
        let model = UpdateStateModel()
        #expect(model.state == .idle)
        #expect(!model.showsPill)
        #expect(model.iconName == nil)
        #expect(model.text.isEmpty)
    }

    @Test func notFoundProducesTitleAndIcon() {
        let model = UpdateStateModel()
        model.setState(.notFound(.init(acknowledgement: {})))
        #expect(model.iconName == "info.circle")
        #expect(!model.text.isEmpty)
    }

    @Test func preparingCheckCopyDoesNotAssumeAnExistingSession() {
        let model = UpdateStateModel()
        model.setState(.preparingCheck(.init(cancel: {})))
        #expect(model.description == "Waiting for the updater to become ready")
    }

    @Test func networkErrorTitleIsUserFacing() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let title = UpdateStateModel.userFacingErrorTitle(for: offline)
        #expect(title == "No Internet Connection")
    }

    @Test func phaseNeutralNetworkMessagesSurviveSparkleWrapping() {
        let cases: [(code: Int, expected: String)] = [
            (
                NSURLErrorNotConnectedToInternet,
                "cmux can’t reach the update service. Check your internet connection and try again."
            ),
            (
                NSURLErrorTimedOut,
                "The update operation timed out. Try again in a moment."
            ),
            (
                NSURLErrorNetworkConnectionLost,
                "The network connection was lost while updating cmux. Try again."
            ),
        ]

        for testCase in cases {
            let networkError = NSError(domain: NSURLErrorDomain, code: testCase.code)
            let wrappedError = NSError(
                domain: SUSparkleErrorDomain,
                code: 2001,
                userInfo: [NSUnderlyingErrorKey: networkError]
            )

            #expect(UpdateStateModel.userFacingErrorMessage(for: networkError) == testCase.expected)
            #expect(UpdateStateModel.userFacingErrorMessage(for: wrappedError) == testCase.expected)
        }
    }

    @Test func errorDetailsIncludesLogPath() {
        let err = NSError(domain: "cmux.update", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let details = UpdateErrorDetailsFormatter().details(for: err, technicalDetails: "ctx", feedURLString: "https://feed", logPath: "/tmp/x.log")
        #expect(details.contains("Log: /tmp/x.log"))
        #expect(details.contains("Feed: https://feed"))
        #expect(details.contains("Debug: ctx"))
    }

    @Test func normalizedVersionTrimsAndRejectsEmpty() {
        #expect(UpdateStateModel.normalizedDetectedUpdateVersion(from: "  1.2.3 ") == "1.2.3")
        #expect(UpdateStateModel.normalizedDetectedUpdateVersion(from: "   ") == nil)
    }

    // MARK: - Installer / launchd-agent failure (SUInstallationError 4005, SUAgentInvalidationError 4010)
    //
    // Domain literal "SUSparkleErrorDomain" matches the value of Sparkle's `SUSparkleErrorDomain`
    // constant, so tests don't need to import Sparkle. Title/message assertions check English
    // substrings because `String(localized:)` falls back to its `defaultValue` under the test bundle.

    /// Regression: a 4005 installation error wrapping an agent-connection timeout (the wedged
    /// launchd-session case) adds restart guidance on top of the existing "move into Applications"
    /// guidance, rather than replacing it. Both must be present.
    @Test func installerAgentFailureKeepsRelocateGuidanceAndAddsRestart() {
        let underlying = NSError(
            domain: "SUSparkleErrorDomain",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Timeout: agent connection was never initiated"]
        )
        let err = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4005,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while running the updater.",
                NSUnderlyingErrorKey: underlying,
            ]
        )
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("Applications"))
        #expect(message.localizedCaseInsensitiveContains("restart"))
    }

    @Test func installerAgentFailureHasOwnTitleAndOffersManualDownload() {
        let underlying = NSError(domain: "SUSparkleErrorDomain", code: 10)
        let err = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4005,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(UpdateStateModel.userFacingErrorTitle(for: err).contains("Start Updater"))
        #expect(UpdateManualDownloadRecovery().url(for: err)?.absoluteString.hasSuffix("cmux-macos.dmg") == true)
    }

    @Test func agentInvalidationErrorIsTreatedAsAgentFailure() {
        let err = NSError(domain: "SUSparkleErrorDomain", code: 4010)
        #expect(UpdateStateModel.userFacingErrorTitle(for: err).contains("Start Updater"))
        #expect(UpdateManualDownloadRecovery().url(for: err) != nil)
    }

    @Test func genericInstallFailureUsesInstallationTitleAndOffersDownload() {
        let err = NSError(domain: "SUSparkleErrorDomain", code: 4005)
        let title = UpdateStateModel.userFacingErrorTitle(for: err)
        #expect(!title.contains("Start Updater"))
        #expect(title.contains("Installation"))
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("install"))
        #expect(!message.localizedCaseInsensitiveContains("Applications"))
        #expect(!message.localizedCaseInsensitiveContains("restart"))
        #expect(UpdateManualDownloadRecovery().url(for: err) != nil)
    }

    @Test func downloadFailureCopyDoesNotMisdiagnoseTheUpdateFeed() {
        let err = NSError(domain: SUSparkleErrorDomain, code: 2001)
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("download"))
        #expect(!message.localizedCaseInsensitiveContains("update feed"))
    }

    @Test func unknownFailureUsesOperationNeutralCopy() {
        let err = NSError(domain: SUSparkleErrorDomain, code: 9999)
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("updating cmux"))
        #expect(!message.localizedCaseInsensitiveContains("checking for updates"))
    }

    @Test func updaterReadinessTimeoutDoesNotInventAStartupCause() {
        let err = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.updaterNotReadyCode,
            userInfo: [NSLocalizedDescriptionKey: "Updater is still starting."]
        )
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("isn’t ready"))
        #expect(!message.localizedCaseInsensitiveContains("starting"))
    }

    @Test func appcastReleaseNotesURLWinsOverVersionDerivedStableTag() throws {
        let nightlyURL = try #require(URL(string: "https://github.com/manaflow-ai/cmux/releases/tag/nightly"))
        let item = SUAppcastItem(dictionary: [
            "title": "cmux nightly",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "sparkle:fullReleaseNotesLink": nightlyURL.absoluteString,
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "101",
                "sparkle:shortVersionString": "0.64.20-nightly.101",
            ],
        ]) ?? SUAppcastItem.empty()
        let update = UpdateState.UpdateAvailable(appcastItem: item, reply: { _ in })

        #expect(update.releaseNotes?.url == nightlyURL)
        #expect(UpdateState.ReleaseNotes(appcastItem: item)?.url == nightlyURL)
    }

    /// A 4005 wrapping a non-agent installer cause (auth failure, relaunch failure) must NOT be
    /// classified as a restart-fixable agent failure, since restarting won't help. It should fall
    /// through to the generic install-failed copy (which still offers a manual download).
    @Test(arguments: [4001, 4004])
    func installFailureWrappingNonAgentCauseIsNotAgentFailure(underlyingCode: Int) {
        let underlying = NSError(domain: "SUSparkleErrorDomain", code: underlyingCode, userInfo: [
            NSLocalizedDescriptionKey: "Authorization or relaunch failed.",
        ])
        let err = NSError(domain: "SUSparkleErrorDomain", code: 4005, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while running the updater.",
            NSUnderlyingErrorKey: underlying,
        ])
        let title = UpdateStateModel.userFacingErrorTitle(for: err)
        #expect(!title.contains("Start Updater"))
        #expect(title.contains("Installation"))
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(!message.localizedCaseInsensitiveContains("Applications"))
        #expect(!message.localizedCaseInsensitiveContains("restart"))
        #expect(UpdateManualDownloadRecovery().url(for: err) != nil)
    }

    /// The agent-connection text signal classifies the failure even when no underlying error is
    /// present (some Sparkle traces only carry the message on the top-level 4005).
    @Test func installFailureWithAgentTextIsAgentFailure() {
        let err = NSError(domain: "SUSparkleErrorDomain", code: 4005, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while running the updater.",
            NSLocalizedFailureReasonErrorKey: "The remote port connection was invalidated from the updater.",
        ])
        #expect(UpdateStateModel.userFacingErrorTitle(for: err).contains("Start Updater"))
    }

    @Test func downloadErrorOffersManualDownload() {
        let err = NSError(domain: "SUSparkleErrorDomain", code: 2001)
        #expect(UpdateManualDownloadRecovery().url(for: err) != nil)
    }

    @Test(arguments: [1000, 1001, 1002, 3, 4, 3001, 3002, 4006])
    func feedSignatureAndNoUpdateErrorsDoNotOfferManualDownload(code: Int) {
        let err = NSError(domain: "SUSparkleErrorDomain", code: code)
        #expect(UpdateManualDownloadRecovery().url(for: err) == nil)
    }

    @Test func diskImageErrorStillSaysMoveToApplications() {
        let err = NSError(domain: "SUSparkleErrorDomain", code: 1003)
        let message = UpdateStateModel.userFacingErrorMessage(for: err)
        #expect(message.localizedCaseInsensitiveContains("Applications"))
        #expect(UpdateManualDownloadRecovery().url(for: err) == nil)
    }

    @Test func nonSparkleErrorHasNoManualDownload() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(UpdateManualDownloadRecovery().url(for: err) == nil)
    }

    @Test func errorDetailsNamesInstallationError() {
        let err = NSError(
            domain: "SUSparkleErrorDomain",
            code: 4005,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let details = UpdateErrorDetailsFormatter().details(
            for: err,
            technicalDetails: nil,
            feedURLString: nil,
            logPath: "/tmp/x.log"
        )
        #expect(details.contains("SUInstallationError"))
    }
}
