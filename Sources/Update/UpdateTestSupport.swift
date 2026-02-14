#if DEBUG
import Foundation
import Sparkle

enum UpdateTestSupport {
    static func applyIfNeeded(to viewModel: UpdateViewModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1" else { return }
        guard let state = env["CMUX_UI_TEST_UPDATE_STATE"] else { return }

        DispatchQueue.main.async {
            switch state {
            case "available":
                let version = env["CMUX_UI_TEST_UPDATE_VERSION"] ?? "9.9.9"
                transition(to: .updateAvailable(.init(
                    appcastItem: makeAppcastItem(displayVersion: version) ?? SUAppcastItem.empty(),
                    reply: { _ in }
                )), on: viewModel)
            case "notFound":
                transition(to: .notFound(.init(acknowledgement: {})), on: viewModel)
            default:
                break
            }
        }
    }

    static func performMockFeedCheckIfNeeded(on viewModel: UpdateViewModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" else { return false }
        guard let feedURLString = env["CMUX_UI_TEST_FEED_URL"],
              let feedURL = URL(string: feedURLString) else { return false }

        UpdateLogStore.shared.append("ui test mock feed check: \(feedURLString)")
        UpdateTestURLProtocol.registerIfNeeded()
        DispatchQueue.main.async {
            viewModel.state = .checking(.init(cancel: {}))
        }

        let task = URLSession.shared.dataTask(with: feedURL) { data, _, _ in
            let xml = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let version = env["CMUX_UI_TEST_UPDATE_VERSION"] ?? "9.9.9"
            let hasItem = xml.contains("<item>")
            let applyState = {
                if hasItem {
                    let appcastItem = makeAppcastItem(displayVersion: version) ?? SUAppcastItem.empty()
                    viewModel.state = .updateAvailable(.init(appcastItem: appcastItem, reply: { _ in }))
                } else {
                    viewModel.state = .notFound(.init(acknowledgement: {}))
                }
            }
            DispatchQueue.main.async {
                let delayMilliseconds = Int(env["CMUX_UI_TEST_MOCK_FEED_DELAY_MS"] ?? "") ?? 0
                if delayMilliseconds > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
                        applyState()
                    }
                } else {
                    applyState()
                }
            }
        }
        task.resume()
        return true
    }

    private static func transition(to state: UpdateState, on viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {}))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            viewModel.state = state
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
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dict)
    }
}
#endif
