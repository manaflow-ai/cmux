import Foundation

extension WorkspaceTerminalFontSizeSnapshotProjection {
    struct Intent {
        let acceptedOrder: UInt64
        let requestSequence: UInt64
        let requestToken: UUID
        let requestTransferToken: UUID
        let counterpartTransferToken: UUID
        let change: WorkspaceTerminalFontSizeChange
        let configuredRuntimePoints: Float32
        let magnificationPercent: Int

        static func precedes(_ lhs: Intent, _ rhs: Intent) -> Bool {
            if lhs.acceptedOrder != rhs.acceptedOrder {
                return lhs.acceptedOrder < rhs.acceptedOrder
            }
            if lhs.requestSequence != rhs.requestSequence {
                return lhs.requestSequence < rhs.requestSequence
            }
            return lhs.requestToken.uuidString
                < rhs.requestToken.uuidString
        }
    }
}
