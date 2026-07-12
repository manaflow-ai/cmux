import Foundation

/// Captures fail-open decoder diagnostics.
public struct TranscriptDecoderDiagnostics: Hashable, Sendable {
    /// Counts of unrecognized record or block kinds by raw kind string.
    public var unknownKindCounts: [String: Int]
    /// Counts of recognized transcript shapes consumed as modeled decoder facts.
    ///
    /// Some modeled shapes emit entries, such as status rows. Others are
    /// diagnostic-only skips, such as duplicate streams or telemetry.
    public var modeledKindCounts: [String: Int]
    /// Counts of duplicate stream records consumed without entries.
    public var duplicateStreamCounts: [String: Int]
    /// Counts of Claude bookkeeping records consumed without entries.
    public var bookkeepingKindCounts: [String: Int]
    /// The CLI version observed in transcript metadata, when present.
    public var cliVersion: String?
    /// Transcript-derived phase corroboration facts.
    public var phaseFacts: [PhaseFact]
    /// Codex turn-context capability facts.
    public var turnContextFacts: [TurnContextFact]
    /// Whether the decoder saw an API error marker.
    public var sawApiError: Bool
    /// Sensitive title-like values for later session-list enrichment.
    public var sensitiveSessionTitles: [SensitiveSessionTitleFact]

    /// Creates decoder diagnostics.
    /// - Parameters:
    ///   - unknownKindCounts: Counts of unrecognized kinds.
    ///   - modeledKindCounts: Counts of modeled decoder facts.
    ///   - duplicateStreamCounts: Counts of duplicate stream kinds.
    ///   - bookkeepingKindCounts: Counts of Claude bookkeeping kinds.
    ///   - cliVersion: The observed CLI version.
    ///   - phaseFacts: Transcript-derived phase facts.
    ///   - turnContextFacts: Codex turn-context facts.
    ///   - sawApiError: Whether an API error marker was observed.
    ///   - sensitiveSessionTitles: Sensitive title-like values.
    public init(
        unknownKindCounts: [String: Int] = [:],
        modeledKindCounts: [String: Int] = [:],
        duplicateStreamCounts: [String: Int] = [:],
        bookkeepingKindCounts: [String: Int] = [:],
        cliVersion: String? = nil,
        phaseFacts: [PhaseFact] = [],
        turnContextFacts: [TurnContextFact] = [],
        sawApiError: Bool = false,
        sensitiveSessionTitles: [SensitiveSessionTitleFact] = []
    ) {
        self.unknownKindCounts = unknownKindCounts
        self.modeledKindCounts = modeledKindCounts
        self.duplicateStreamCounts = duplicateStreamCounts
        self.bookkeepingKindCounts = bookkeepingKindCounts
        self.cliVersion = cliVersion
        self.phaseFacts = phaseFacts
        self.turnContextFacts = turnContextFacts
        self.sawApiError = sawApiError
        self.sensitiveSessionTitles = sensitiveSessionTitles
    }

}
