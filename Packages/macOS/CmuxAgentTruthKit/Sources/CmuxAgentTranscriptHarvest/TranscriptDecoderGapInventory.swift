import CmuxAgentTruthKit
import Foundation

/// Tracks decoder-reported unknowns and the shape rows they should annotate.
///
/// `DECODER-GAP` means the real decoder diagnostics counted at least one
/// occurrence of the row's value as unknown. The marker does not mean every
/// occurrence in the frequency row was unknown; exact unknown counts are emitted
/// separately as `decoder_unknown` rows. Claude diagnostics preserve only the
/// raw unknown kind, so this inventory uses the raw line to recover record-type
/// versus block-type origin. If a malformed or future shape cannot be
/// disambiguated, it may mark both possible dimensions.
struct TranscriptDecoderGapInventory: Codable, Equatable, Sendable {
    private var markerKeys: Set<TranscriptDecoderGapKey>
    private var counts: [TranscriptDecoderUnknownKey: Int]

    init() {
        self.markerKeys = []
        self.counts = [:]
    }

    mutating func record(source: TranscriptHarvestSource, rawLine: String, diagnostics: TranscriptDecoderDiagnostics) {
        for (rawKind, count) in diagnostics.unknownKindCounts {
            guard count > 0 else {
                continue
            }
            for mapped in TranscriptDecoderGapMapper.map(source: source, rawKind: rawKind, rawLine: rawLine) {
                let sanitizedValue = TranscriptPrivacySanitizer.identifier(mapped.value)
                markerKeys.insert(TranscriptDecoderGapKey(source: source, dimension: mapped.dimension, value: sanitizedValue))
            }
            let key = TranscriptDecoderUnknownKey(source: source, value: TranscriptPrivacySanitizer.identifier(rawKind))
            counts[key, default: 0] += count
        }
    }

    func contains(source: TranscriptHarvestSource, dimension: String, value: String) -> Bool {
        markerKeys.contains(TranscriptDecoderGapKey(source: source, dimension: dimension, value: value))
    }

    func summaryRows() -> [TranscriptShapeRow] {
        counts.map { key, count in
            TranscriptShapeRow(
                source: key.source,
                dimension: "decoder_unknown",
                value: key.value,
                count: count,
                marker: "DECODER-GAP"
            )
        }
        .sorted { lhs, rhs in
            if lhs.source.rawValue != rhs.source.rawValue {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            if lhs.dimension != rhs.dimension {
                return lhs.dimension < rhs.dimension
            }
            return lhs.value < rhs.value
        }
    }
}
