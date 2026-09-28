internal import CoreFoundation
internal import Foundation

/// Reads the signed-in user's `com.apple.screencapture` preferences.
///
/// The Screenshot app (Shift-Command-5 > Options) and `screencapture` write
/// this domain. The reader only calls `CFPreferencesCopyAppValue`; cmux never
/// writes or deletes anything in it.
public struct SystemScreenCapturePreferences: ScreenCapturePreferenceReading {
    /// The preference domain macOS stores screenshot options in.
    public static let domain = "com.apple.screencapture"

    /// Creates a reader for the current user's screenshot preferences.
    public init() {}

    /// Returns the string stored for `key` in `com.apple.screencapture`, or nil.
    ///
    /// - Parameter key: A key such as `location`, `name` or `type`.
    /// - Returns: The stored string, or nil when it is absent or not a string.
    public func string(forKey key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, Self.domain as CFString) as? String
    }
}
