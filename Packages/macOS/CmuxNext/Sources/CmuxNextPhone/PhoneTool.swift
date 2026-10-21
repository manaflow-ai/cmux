/// A developer tool a phone mode needs. When one is missing the phone tab
/// shows how to get it instead of an empty list.
public enum PhoneTool: String, Sendable, Hashable, Codable, CaseIterable {
    /// Xcode (for `simctl` and `devicectl`): iOS simulators and iPhones.
    case xcode
    /// The Android SDK with platform-tools and the emulator: Android phones.
    case androidSDK = "android-sdk"
}
