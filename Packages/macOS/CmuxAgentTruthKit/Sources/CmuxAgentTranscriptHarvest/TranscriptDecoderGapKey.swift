import Foundation

struct TranscriptDecoderGapKey: Codable, Hashable, Sendable {
    var source: TranscriptHarvestSource
    var dimension: String
    var value: String
}
