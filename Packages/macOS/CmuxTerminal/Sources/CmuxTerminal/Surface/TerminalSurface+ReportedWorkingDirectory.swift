import Foundation

extension TerminalSurface {
    /// Records the latest working directory emitted by this surface's shell integration.
    ///
    /// An empty report clears the directory, matching Ghostty's OSC 7 reset semantics.
    ///
    /// - Parameter directory: The working directory reported by Ghostty.
    @MainActor
    public func recordReportedWorkingDirectory(_ directory: String) {
        let reportedDirectory = directory.isEmpty ? nil : directory
        guard reportedDirectory != reportedWorkingDirectory else { return }
        reportedWorkingDirectory = reportedDirectory
    }
}
