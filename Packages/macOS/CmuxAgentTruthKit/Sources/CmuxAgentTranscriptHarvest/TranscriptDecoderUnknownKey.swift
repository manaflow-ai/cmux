import Foundation

struct TranscriptDecoderUnknownKey: Codable, Hashable, Sendable {
    var source: TranscriptHarvestSource
    var value: String
}
