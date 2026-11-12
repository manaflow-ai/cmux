import Foundation

extension CloudReadCooldownStore {
    public struct Session: Equatable, Sendable {
        public let accountID: String?
        public let generation: UInt64?

        public init(
            accountID: String?,
            generation: UInt64?
        ) {
            self.accountID = accountID
            self.generation = generation
        }
    }
}
