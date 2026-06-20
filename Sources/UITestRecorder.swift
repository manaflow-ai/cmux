import CmuxTestSupport
import Foundation

#if DEBUG
/// Lightweight JSON recorder for UI tests.
///
/// XCUITests can’t easily introspect internal app state (tab count, actions invoked, etc).
/// When `CMUX_UI_TEST_KEYEQUIV_PATH` is set, we persist small counters/fields here so tests
/// can assert that menu key equivalents were actually routed and handled.
enum UITestRecorder {
    private static var path: String? {
        let env = ProcessInfo.processInfo.environment
        guard let p = env["CMUX_UI_TEST_KEYEQUIV_PATH"], !p.isEmpty else { return nil }
        return p
    }

    static func record(_ updates: [String: String]) {
        guard let path else { return }
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }

    static func incrementInt(_ key: String) {
        guard let path else { return }
        let file = UITestKeyValueCaptureFile(path: path)
        let value = Int(file.load()[key] ?? "") ?? 0
        file.merge([key: String(value + 1)])
    }
}
#endif

