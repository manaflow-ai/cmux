@testable import CmuxTerminal

/// Fixed `com.apple.screencapture` values, so tests never read the user's preferences.
struct FakeScreenCapturePreferences: ScreenCapturePreferenceReading {
    var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        values[key]
    }
}
