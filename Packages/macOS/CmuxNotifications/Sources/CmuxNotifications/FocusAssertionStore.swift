public import Foundation

/// Reader for the live macOS Do Not Disturb / Focus assertion store written by
/// the Focus daemon (`~/Library/DoNotDisturb/DB/Assertions.json`).
///
/// A value bound to one assertions-file URL; `isSuppressedByActiveFocus`
/// answers whether any Focus is currently active by inspecting that file. The
/// read is fail-open, so any read or parse error reports "no Focus active".
public struct FocusAssertionStore: Sendable {
    /// Assertions file the Focus daemon writes its live records to.
    public let assertionsFileURL: URL

    /// Default location of the live assertion store written by the Focus daemon.
    ///
    /// DEBUG builds honor `CMUX_DEBUG_DND_ASSERTIONS_PATH` so a tagged dev app
    /// can be driven end-to-end against fixture files instead of the real
    /// (TCC-protected) store.
    public static let defaultAssertionsFileURL: URL = {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["CMUX_DEBUG_DND_ASSERTIONS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
#endif
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json", isDirectory: false)
    }()

    /// Creates a store reading `assertionsFileURL`, defaulting to the live store.
    public init(assertionsFileURL: URL = FocusAssertionStore.defaultAssertionsFileURL) {
        self.assertionsFileURL = assertionsFileURL
    }

    /// Whether a macOS Focus / Do Not Disturb mode is currently active.
    ///
    /// The `UNUserNotificationCenter` sound path is gated by the OS for Focus
    /// and per-app authorization. The direct `NSSound` fallback (used when the
    /// system would not deliver the banner) is not, so it otherwise punches
    /// through Focus and through a user who has turned notifications off. A
    /// Focus is active when `storeAssertionRecords` holds at least one
    /// assertion. Fails open: any read or parse error returns `false` so sound
    /// keeps working.
    public var isSuppressedByActiveFocus: Bool {
        guard
            let data = try? Data(contentsOf: assertionsFileURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else {
            return false
        }
        return entries.contains { entry in
            if let records = entry["storeAssertionRecords"] as? [Any] {
                return !records.isEmpty
            }
            return false
        }
    }
}
