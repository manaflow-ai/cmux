public import Foundation

/// Launches the vendor Android Emulator as a long-lived external process.
public protocol AndroidEmulatorProcessLaunching: Sendable {
    /// Starts one AVD on a reserved console port and returns its process identity after spawn.
    ///
    /// - Parameters:
    ///   - executableURL: The installed Android Emulator executable.
    ///   - avdName: The validated AVD name.
    ///   - sdkRootURL: The selected SDK root.
    ///   - consolePort: The reserved even-numbered emulator console port.
    /// - Returns: The spawned process identity used for cleanup if confirmation fails.
    func launch(executableURL: URL, avdName: String, sdkRootURL: URL, consolePort: Int) async throws -> UUID

    /// Terminates a spawned emulator process whose launch could not be confirmed.
    ///
    /// - Parameter processID: The process identity returned by ``launch(executableURL:avdName:sdkRootURL:consolePort:)``.
    func terminate(processID: UUID) async
}
