import Foundation

package enum TranscriptHarvestSource: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
}
