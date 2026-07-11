public import Foundation

/// Executable Android SDK components discovered on the user's Mac.
public struct AndroidSDKInstallation: Sendable, Equatable {
    /// The Android SDK root directory.
    public let rootURL: URL

    /// The vendor-supplied Android Emulator executable.
    public let emulatorURL: URL

    /// The vendor-supplied Android Debug Bridge executable, when installed.
    public let adbURL: URL?

    /// Creates a discovered Android SDK installation.
    ///
    /// - Parameters:
    ///   - rootURL: The Android SDK root directory.
    ///   - emulatorURL: The Android Emulator executable.
    ///   - adbURL: The Android Debug Bridge executable, when installed.
    public init(rootURL: URL, emulatorURL: URL, adbURL: URL?) {
        self.rootURL = rootURL
        self.emulatorURL = emulatorURL
        self.adbURL = adbURL
    }
}
