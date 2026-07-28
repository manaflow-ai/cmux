import Foundation

extension TerminalSurface {
    /// Records the latest working directory emitted by this surface's shell integration.
    ///
    /// Empty reports do not erase the last usable directory.
    ///
    /// - Parameter directory: The working directory reported by Ghostty.
    @MainActor
    public func recordReportedWorkingDirectory(_ directory: String) {
        let normalized = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != reportedWorkingDirectory else { return }
        reportedWorkingDirectory = normalized
    }
}
