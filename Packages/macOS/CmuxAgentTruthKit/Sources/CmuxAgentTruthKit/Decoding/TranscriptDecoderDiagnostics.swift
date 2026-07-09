import Foundation

/// Captures fail-open decoder diagnostics.
public struct TranscriptDecoderDiagnostics: Hashable, Sendable {
    /// Counts of unrecognized record or block kinds by raw kind string.
    public var unknownKindCounts: [String: Int]
    /// The CLI version observed in transcript metadata, when present.
    public var cliVersion: String?

    /// Creates decoder diagnostics.
    /// - Parameters:
    ///   - unknownKindCounts: Counts of unrecognized kinds.
    ///   - cliVersion: The observed CLI version.
    public init(unknownKindCounts: [String: Int] = [:], cliVersion: String? = nil) {
        self.unknownKindCounts = unknownKindCounts
        self.cliVersion = cliVersion
    }
}
