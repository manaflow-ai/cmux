public import Foundation

/// Result of searching the user's machine for Android SDK tools.
public enum AndroidSDKResolution: Sendable, Equatable {
    /// A usable emulator executable was found.
    case available(AndroidSDKInstallation)

    /// An SDK root exists, but it does not contain the emulator component.
    case emulatorMissing(rootURL: URL)

    /// No configured or conventional Android SDK root exists.
    case sdkNotFound
}
