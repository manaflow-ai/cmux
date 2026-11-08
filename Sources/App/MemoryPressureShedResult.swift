import Foundation

struct MemoryPressureShedResult: Equatable, Sendable {
    let reclaimedItemCount: Int
    let estimatedBytes: UInt64?
    let detail: String?

    init(
        reclaimedItemCount: Int,
        estimatedBytes: UInt64? = nil,
        detail: String? = nil
    ) {
        self.reclaimedItemCount = max(0, reclaimedItemCount)
        self.estimatedBytes = estimatedBytes
        self.detail = detail
    }
}
