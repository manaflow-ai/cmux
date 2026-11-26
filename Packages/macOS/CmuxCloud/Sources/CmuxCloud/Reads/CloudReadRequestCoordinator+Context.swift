import Foundation

extension CloudReadRequestCoordinator {
    public struct Context: Sendable {
        public weak var owner: CloudReadRequestCoordinator?
        public let key: Key

        public init(
            owner: CloudReadRequestCoordinator? = nil,
            key: Key
        ) {
            self.owner = owner
            self.key = key
        }
    }
}
