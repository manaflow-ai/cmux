import Foundation

extension CloudReadRequestCoordinator {
    public struct Key: Hashable, Sendable {
        public init(
            path: String,
            accountID: String? = nil,
            generation: UInt64? = nil,
            teamID: String? = nil
        ) {
            self.path = path
            self.accountID = accountID
            self.generation = generation
            self.teamID = teamID
        }

        public let path: String
        public let accountID: String?
        public let generation: UInt64?
        public let teamID: String?
    }
}
