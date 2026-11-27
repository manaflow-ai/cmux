import Foundation

/// Executes one notification-sound codec conversion asynchronously.
protocol NotificationSoundProcessRunning: Sendable {
    /// Converts one source file into the staged destination.
    ///
    /// - Parameters:
    ///   - sourceURL: Original user-selected sound file.
    ///   - destinationURL: Managed artifact path to write.
    /// - Returns: The process status and bounded diagnostic output.
    /// - Throws: When conversion cannot be launched or is canceled.
    func run(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws -> NotificationSoundProcessRunner.Result
}
