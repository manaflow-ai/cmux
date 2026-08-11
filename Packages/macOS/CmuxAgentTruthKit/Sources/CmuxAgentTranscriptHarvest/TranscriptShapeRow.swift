import Foundation

package struct TranscriptShapeRow: Codable, Equatable, Sendable {
    package var source: TranscriptHarvestSource
    package var dimension: String
    package var value: String
    package var count: Int
    /// `DECODER-GAP` when decoders counted at least one occurrence as unknown.
    ///
    /// The marker is row-level annotation only; exact unknown counts are emitted
    /// in the separate `decoder_unknown` rows.
    package var marker: String?

    package init(
        source: TranscriptHarvestSource,
        dimension: String,
        value: String,
        count: Int,
        marker: String? = nil
    ) {
        self.source = source
        self.dimension = dimension
        self.value = value
        self.count = count
        self.marker = marker
    }
}
