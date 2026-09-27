/// Reads values from the macOS screenshot preference domain, `com.apple.screencapture`.
///
/// ``ScreenshotLocator`` takes a reader through its initializer, so tests can
/// supply fixed preferences instead of the signed-in user's.
public protocol ScreenCapturePreferenceReading {
    /// Returns the string stored for `key`, or nil when the key is absent or not a string.
    ///
    /// - Parameter key: A key in the `com.apple.screencapture` domain, such as `location`.
    /// - Returns: The stored string, or nil.
    func string(forKey key: String) -> String?
}
