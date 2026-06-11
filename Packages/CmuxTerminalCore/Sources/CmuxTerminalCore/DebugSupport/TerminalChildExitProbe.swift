#if DEBUG
import Foundation

/// UI-test scaffolding that journals child-exit keyboard handling to a probe
/// file.
///
/// The child-exit XCUITests launch the app with
/// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP=1` and a probe path; the surface
/// view records key-routing decisions into that JSON file so the test can
/// assert on the exact path a keystroke took. Compiled only for DEBUG and
/// inert unless the environment opts in.
///
/// Static members are justified here: the probe is process-wide test
/// scaffolding keyed off the process environment, with no instance state.
public struct TerminalChildExitProbe {
    private init() {}

    /// The probe file path, or `nil` unless the UI-test environment opts in.
    public static func probePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Loads the probe payload at a path, returning an empty payload when the
    /// file is missing or malformed.
    ///
    /// - Parameter path: The probe file path.
    public static func load(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    /// Merges updates and counter increments into the environment-selected
    /// probe file. A no-op when the environment does not opt in.
    ///
    /// - Parameters:
    ///   - updates: Values written over the existing payload.
    ///   - increments: Counters added to the existing numeric values.
    public static func write(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = probePath() else { return }
        var payload = load(at: path)
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
