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

/// Records keyboard-probe diagnostics for the child-exit (Ctrl+D) XCUITest
/// scenario into a JSON file the test harness reads back.
///
/// This is a self-contained DEBUG-only diagnostic: it reads only
/// `ProcessInfo.environment` for its gate and target path, formats UTF-16 code
/// points to hex, and read-merge-writes a flat `[String: String]` JSON payload.
/// It holds no `AppDelegate` (or any other app) state, so it is a plain
/// `Sendable` value type constructed from the process environment; the live
/// dispatch path holds one instance and forwards to it.
///
/// All three operations are no-ops unless both
/// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP == "1"` and a non-empty
/// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH` are present, matching the legacy
/// `AppDelegate` gate, so production launches never touch the filesystem.
///
/// Faithful lift: the `%04X` UTF-16 hex formatting, the comma-joined scalar
/// list, the read-merge-write semantics (increments applied before updates),
/// and the `.atomic` write are preserved verbatim from the original
/// `AppDelegate` implementation; the file's wire format is part of the
/// scenario's contract.
struct ChildExitKeyboardProbeRecorder: Sendable {
    private let environment: [String: String]

    /// - Parameter environment: The process environment; defaults to the real
    ///   one. The recorder reads only its gate and target-path keys from it.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// The probe-file path, or `nil` when the scenario is not active (gate off
    /// or path missing/empty).
    private var probePath: String? {
        guard environment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = environment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Formats `value`'s unicode scalars as a comma-joined list of four-digit
    /// uppercase hex code points, or `""` when `value` is `nil`.
    func hex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    /// Read-merge-writes the probe JSON file: increments the named counters,
    /// then applies the literal string updates, then atomically writes the
    /// result. A no-op when the scenario is inactive.
    func write(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = probePath else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif

