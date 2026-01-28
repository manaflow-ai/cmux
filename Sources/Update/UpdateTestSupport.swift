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
