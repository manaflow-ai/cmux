import Foundation

extension CloudReadCooldownStore {
    public struct Session: Equatable, Sendable {
        public let accountID: String?
        public let generation: UInt64?
    }
}
