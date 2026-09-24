import Foundation

extension CloudReadRequestCoordinator {
    struct Key: Hashable, Sendable {
        let path: String
        let accountID: String?
        let generation: UInt64?
        let teamID: String?
    }
}
