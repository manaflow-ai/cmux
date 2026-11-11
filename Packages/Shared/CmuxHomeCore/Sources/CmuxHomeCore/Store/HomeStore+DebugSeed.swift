#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

// DEBUG and bench builds only (`CMUX_BENCH_HOOKS`): a long transcript for the pane-resize films.
extension HomeStore {
    /// The row counts ``debugSeed(_:rows:image:)`` takes.
    public static let debugSeedSizes = [50, 500, 5000]

    /// How many rows of each kind (`text`, `code`, `tool`, `image`) a seed of `rows` rows has.
    public static func debugSeedKinds(rows: Int) -> [String: Int] {
        [:]
    }

    /// Puts `rows` generated messages in the loaded window of `id`. A stub: it seeds nothing yet.
    @discardableResult
    public func debugSeed(_ id: ConversationID, rows: Int, image: AttachmentRef? = nil) async -> Bool {
        false
    }
}
#endif
