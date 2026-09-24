import Foundation

extension CloudReadCooldownStore {
    struct Session: Equatable, Sendable {
        let accountID: String?
        let generation: UInt64?
    }
}
