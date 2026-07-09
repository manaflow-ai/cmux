public import Foundation

/// Writes the env-driven child-exit keyboard probe JSON the
/// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_*` XCUITest scenario reads back.
///
/// This recorder owns the byte-identical merge-and-write the legacy
/// `AppDelegate.writeChildExitKeyboardProbe(_:increments:)` produced: it reads
/// the existing `[String: String]` JSON at
/// `CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH`, applies integer increments and
/// string updates, and re-serializes with **unsorted** keys
/// (`JSONSerialization.data(withJSONObject:)` with no options) to match the
/// legacy writer on disk. It reads no live app state; the only input besides
/// the caller's updates is the process environment, captured at init so tests
/// can pass a fixture.
///
/// The recorder is `@MainActor` because every legacy call site ran on
/// `AppDelegate`'s main actor, and the read-modify-write of the probe file
/// relied on that serialization; co-locating the isolation keeps the writes
/// ordered exactly as before. The whole facility is debug-only test scaffolding,
/// so the app holds it behind `#if DEBUG`.
@MainActor
public final class ChildExitKeyboardProbeRecorder {
    private let environment: [String: String]

    /// Creates a probe recorder.
    ///
    /// - Parameter environment: The process environment; tests pass a fixture.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// The probe file path, or `nil` when the child-exit keyboard scenario is
    /// not configured (`CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP` != `"1"` or the
    /// path env var is missing/empty).
    private func probePath() -> String? {
        guard environment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = environment["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Renders a string as a comma-separated list of zero-padded 4-digit
    /// hex Unicode scalar values, matching the legacy probe encoding. Returns
    /// the empty string for `nil`.
    public func hex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    /// Merges `increments` (added to the current integer value of each key) and
    /// `updates` (overwriting string values) into the probe file, or does
    /// nothing when the scenario is not configured.
    public func write(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = probePath() else { return }
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
