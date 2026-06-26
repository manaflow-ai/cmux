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

        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(didAcknowledge)
        #expect(actionDelegate.retryRequestCount == 1)
        #expect(model.state == .checking(.init(cancel: {})))
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

private struct ImmediateUpdateClock: UpdateClock {
    func sleep(for duration: Duration) async throws {}
}

private struct NullUpdateLog: UpdateLogging {
    func append(_ message: String) {}
    func logPath() -> String { "/tmp/cmux-update-test.log" }
}

@MainActor
private final class RecordingUpdateActionDelegate: UpdateActionDelegate {
    private(set) var retryRequestCount = 0
    private(set) var willRelaunchCount = 0

    func updaterRequestsRetryCheckForUpdates() {
        retryRequestCount += 1
    }

    func updaterWillRelaunchApplication() {
        willRelaunchCount += 1
    }
}
