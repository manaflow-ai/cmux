import Foundation
import Testing
@testable import CmuxUpdater

@MainActor
@Suite struct UpdateDriverRetryTests {
    @Test func transientGitHubCDN504SchedulesRetryBeforeSurfacingError() async {
        let model = UpdateStateModel()
        let actionDelegate = RecordingUpdateActionDelegate()
        let driver = UpdateDriver(model: model, log: NullUpdateLog(), clock: ImmediateUpdateClock())
        driver.actionDelegate = actionDelegate
        driver.recordFeedURLString("https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml", usedFallback: false)

        var didAcknowledge = false
        driver.showUpdaterError(
            Self.sparkleDownloadHTTPError(
                statusCode: 504,
                statusText: "gateway timed out",
                urlString: "https://github.com/manaflow-ai/cmux/releases/download/v0.64.14/cmux-macos.dmg"
            ),
            acknowledgement: { didAcknowledge = true }
        )

        await actionDelegate.waitForRetryRequests(atLeast: 1)

        #expect(didAcknowledge)
        #expect(actionDelegate.retryRequestCount == 1)
        #expect(actionDelegate.retryPreserveInstallIntentValues == [false])
        #expect(model.state == .checking(.init(cancel: {})))
    }

    @Test func transientDownloadFailureDuringInstallPreservesInstallIntent() async {
        let model = UpdateStateModel()
        let actionDelegate = RecordingUpdateActionDelegate()
        let driver = UpdateDriver(model: model, log: NullUpdateLog(), clock: ImmediateUpdateClock())
        driver.actionDelegate = actionDelegate
        model.setState(.downloading(.init(cancel: {}, expectedLength: nil, progress: 0)))

        driver.showUpdaterError(
            Self.sparkleDownloadHTTPError(
                statusCode: 504,
                statusText: "gateway timed out",
                urlString: "https://github.com/manaflow-ai/cmux/releases/download/v0.64.14/cmux-macos.dmg"
            ),
            acknowledgement: {}
        )

        await actionDelegate.waitForRetryRequests(atLeast: 1)

        #expect(actionDelegate.retryPreserveInstallIntentValues == [true])
        #expect(model.state == .checking(.init(cancel: {})))
    }

    @Test func userCancelWhileRetryPillAwaitsReadinessReturnsToIdle() async {
        let model = UpdateStateModel()
        let actionDelegate = RecordingUpdateActionDelegate()
        let driver = UpdateDriver(model: model, log: NullUpdateLog(), clock: ImmediateUpdateClock())
        driver.actionDelegate = actionDelegate

        // A transient CDN 504 schedules a retry. With the immediate clock the backoff fires at
        // once and asks the controller to re-check, but the recording delegate never starts a real
        // Sparkle check — so the pill stays parked in `.checking` with the driver's retry cancel
        // closure, exactly as the real controller leaves it while waiting for `canCheckForUpdates`
        // in `waitForReadinessThenCheck`.
        driver.showUpdaterError(
            Self.sparkleDownloadHTTPError(
                statusCode: 504,
                statusText: "gateway timed out",
                urlString: "https://github.com/manaflow-ai/cmux/releases/download/v0.64.14/cmux-macos.dmg"
            ),
            acknowledgement: {}
        )
        await actionDelegate.waitForRetryRequests(atLeast: 1)

        guard case let .checking(checking) = model.state else {
            Issue.record("Expected the fired retry to leave the pill in .checking")
            return
        }

        // Pressing Cancel on the still-checking retry pill must abort the retry and idle the pill.
        // It must not no-op just because the retry-state preserve flag is set for the pending
        // restart (the readiness-wait cancel regression, UpdateDriver.swift).
        checking.cancel()

        #expect(model.state == .idle)
    }

    @Test func nonTransientDownload404SurfacesErrorWithoutRetry() {
        let model = UpdateStateModel()
        let actionDelegate = RecordingUpdateActionDelegate()
        let driver = UpdateDriver(model: model, log: NullUpdateLog(), clock: ImmediateUpdateClock())
        driver.actionDelegate = actionDelegate

        driver.showUpdaterError(
            Self.sparkleDownloadHTTPError(
                statusCode: 404,
                statusText: "not found",
                urlString: "https://github.com/manaflow-ai/cmux/releases/download/v0.64.14/cmux-macos.dmg"
            ),
            acknowledgement: {}
        )

        #expect(actionDelegate.retryRequestCount == 0)
        guard case .error = model.state else {
            Issue.record("Expected a visible update error for non-transient HTTP status")
            return
        }
    }

    @Test func laterTransientStatusIsNotShadowedByEarlierNonTransientStatus() {
        let error = Self.sparkleDownloadHTTPError(
            statusCode: 504,
            statusText: "cached response marker (200); retryable upstream status HTTP 504",
            urlString: "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"
        )

        let delay = UpdateRetryPolicy().delay(afterFailureNumber: 1, for: error)

        #expect(delay == 1)
    }

    private static func sparkleDownloadHTTPError(statusCode: Int, statusText: String, urlString: String) -> NSError {
        let url = URL(string: urlString)!
        let underlying = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [
                NSLocalizedDescriptionKey: "A network error occurred while downloading \(urlString). \(statusText) (\(statusCode))",
            ]
        )
        return NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while downloading the update. Please try again later.",
                NSUnderlyingErrorKey: underlying,
                NSURLErrorFailingURLErrorKey: url,
            ]
        )
    }
}
