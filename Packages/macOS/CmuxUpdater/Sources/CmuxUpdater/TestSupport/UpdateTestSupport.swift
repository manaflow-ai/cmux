#if DEBUG
import Foundation
@preconcurrency import Sparkle

/// Drives the ``UpdateStateModel`` into specific states for UI tests, and can run a mock feed
/// check against an in-process appcast (``UpdateTestURLProtocol``).
///
/// DEBUG-only test scaffolding, gated on `CMUX_UI_TEST_*` environment variables. Constructed by
/// the host with the live model and logger.
@MainActor
public struct UpdateTestSupport {
    let model: UpdateStateModel
    let log: any UpdateLogging

    /// Creates the test-support helper bound to a model and logger.
    public init(model: UpdateStateModel, log: any UpdateLogging) {
        self.model = model
        self.log = log
    }

    /// Applies an initial detected-update banner and/or a forced state from the environment.
    public func applyIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1" else { return }

        if let detectedVersion = env["CMUX_UI_TEST_DETECTED_UPDATE_VERSION"],
           !detectedVersion.isEmpty {
            if let item = Self.makeAppcastItem(displayVersion: detectedVersion) {
                model.recordDetectedUpdate(item)
            } else {
                model.debugSetDetectedVersion(UpdateStateModel.normalizedDetectedUpdateVersion(from: detectedVersion))
            }
        }

        guard let state = env["CMUX_UI_TEST_UPDATE_STATE"] else { return }
        switch state {
        case "available":
            let version = env["CMUX_UI_TEST_UPDATE_VERSION"] ?? "9.9.9"
            transition(to: .updateAvailable(.init(
                appcastItem: Self.makeAppcastItem(displayVersion: version) ?? SUAppcastItem.empty(),
                reply: { _ in }
            )))
        case "notFound":
            transition(to: .notFound(.init(acknowledgement: {})))
        case "downloading":
            transition(to: .downloading(.init(cancel: {}, expectedLength: 100, progress: 50)))
        case "extracting":
            transition(to: .extracting(.init(progress: 0.5)))
        case "installing":
            transition(to: .installing(.init(isAutoUpdate: false, retryTerminatingApplication: {}, dismiss: {})))
        case "error":
            let message = env["CMUX_UI_TEST_UPDATE_ERROR_MESSAGE"] ?? "Test update error"
            let error = NSError(domain: "cmux.update.uitest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            transition(to: .error(.init(
                error: error,
                retry: {},
                dismiss: {},
                technicalDetails: "ui-test error",
                feedURLString: env["CMUX_UI_TEST_FEED_URL"]
            )))
        default:
            break
        }
    }

    /// Runs a mock feed check against `CMUX_UI_TEST_FEED_URL` if requested. Returns whether it ran.
    public func performMockFeedCheckIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" else { return false }
        guard let feedURLString = env["CMUX_UI_TEST_FEED_URL"],
              let feedURL = URL(string: feedURLString) else { return false }

        log.append("ui test mock feed check: \(feedURLString)")
        UpdateTestURLProtocol.registerIfNeeded()
        model.applyDriverState(.checking(.init(cancel: {})))

        let model = self.model
        let task = URLSession.shared.dataTask(with: feedURL) { data, _, _ in
            let xml = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let version = env["CMUX_UI_TEST_UPDATE_VERSION"] ?? "9.9.9"
            let hasItem = xml.contains("<item>")
            let delayMilliseconds = Int(env["CMUX_UI_TEST_MOCK_FEED_DELAY_MS"] ?? "") ?? 0
            Task { @MainActor in
                if delayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                }
                if hasItem {
                    let appcastItem = Self.makeAppcastItem(displayVersion: version) ?? SUAppcastItem.empty()
                    model.applyDriverState(.updateAvailable(.init(appcastItem: appcastItem, reply: { _ in })))
                } else {
                    model.applyDriverState(.notFound(.init(acknowledgement: {})))
                }
            }
        }
        task.resume()
        return true
    }

    private func transition(to state: UpdateState) {
        model.applyDriverState(.checking(.init(cancel: {})))
        let model = self.model
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            model.applyDriverState(state)
        }
    }

    private static func makeAppcastItem(displayVersion: String) -> SUAppcastItem? {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": displayVersion,
            "sparkle:shortVersionString": displayVersion,
        ]
        let dict: [String: Any] = [
            "title": "cmux \(displayVersion)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dict)
    }
}
#endif
