public import Foundation

/// Captures screenshots via `simctl io <udid> screenshot` into a private
/// temporary file, then reads the bytes back.
///
/// `simctl`'s documented `-` (stdout) target does not reliably stream on
/// current Xcode releases — it can write a literal file named `-` in the
/// working directory instead — so this source always passes an explicit
/// temporary path and deletes it after reading (verified against Xcode's
/// simctl during development; see the PR description).
public struct SimctlFileScreenshotSource: SimulatorScreenshotCapturing {
    private let runner: any SimctlCommandRunning
    private let temporaryDirectory: URL

    /// Creates a file-based screenshot source.
    ///
    /// - Parameters:
    ///   - runner: The `simctl` seam.
    ///   - temporaryDirectory: Where capture files are written. Defaults to
    ///     the user's temporary directory.
    public init(
        runner: any SimctlCommandRunning,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.runner = runner
        self.temporaryDirectory = temporaryDirectory
    }

    /// Captures the device's display to a fresh temporary PNG and returns
    /// its bytes; the file is removed before returning.
    ///
    /// - Parameter udid: The device to capture.
    /// - Returns: The PNG bytes.
    /// - Throws: The underlying `simctl` failure, or a Foundation error when
    ///   the written file cannot be read.
    public func captureScreenshot(of udid: SimulatorDeviceUDID) async throws -> Data {
        let captureURL = temporaryDirectory.appendingPathComponent(
            "cmux-simulator-frame-\(UUID().uuidString).png"
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }
        try await runner.run(["io", udid.rawValue, "screenshot", "--type=png", captureURL.path])
        return try Data(contentsOf: captureURL)
    }
}
