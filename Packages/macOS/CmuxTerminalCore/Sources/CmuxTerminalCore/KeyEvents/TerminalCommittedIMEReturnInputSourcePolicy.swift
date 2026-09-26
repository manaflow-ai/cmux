import Foundation

/// Decides whether a committed IME Return should also reach the terminal.
public struct TerminalCommittedIMEReturnInputSourcePolicy: Sendable {
    /// Creates the committed IME Return policy.
    public init() {}

    /// Returns whether the source should forward the Return after committing text.
    ///
    /// - Parameters:
    ///   - sourceId: The input-source identifier, or `nil` when unavailable.
    ///   - languages: The input-source languages, ordered with the primary language first.
    public func shouldForwardReturn(sourceId: String?, languages: [String]) -> Bool {
        guard let sourceId else { return false }
        if sourceId.range(of: "korean", options: .caseInsensitive) != nil { return true }
        return languages.first == "ko"
    }
}
