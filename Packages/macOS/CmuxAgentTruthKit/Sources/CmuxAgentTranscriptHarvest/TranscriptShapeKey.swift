import Foundation

struct TranscriptShapeKey: Hashable, Sendable {
    var source: TranscriptHarvestSource
    var dimension: String
    var value: String
}
