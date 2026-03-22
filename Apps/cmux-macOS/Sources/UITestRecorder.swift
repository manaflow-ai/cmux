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
        var payload = load(at: path)
        for (k, v) in updates {
            payload[k] = v
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func incrementInt(_ key: String) {
        guard let path else { return }
        var payload = load(at: path)
        let value = Int(payload[key] ?? "") ?? 0
        payload[key] = String(value + 1)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func load(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}
#endif

