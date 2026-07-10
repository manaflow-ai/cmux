public import Foundation

/// Launches the vendor Android Emulator as a long-lived external process.
public protocol AndroidEmulatorProcessLaunching: Sendable {
    /// Starts one AVD in the vendor emulator window and returns after spawn.
    ///
    /// - Parameters:
    ///   - executableURL: The installed Android Emulator executable.
    ///   - avdName: The validated AVD name.
    ///   - sdkRootURL: The selected SDK root.
    func launch(executableURL: URL, avdName: String, sdkRootURL: URL) async throws
}
