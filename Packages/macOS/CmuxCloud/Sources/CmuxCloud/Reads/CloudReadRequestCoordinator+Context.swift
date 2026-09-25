import Foundation

extension CloudReadRequestCoordinator {
    public struct Context: Sendable {
        public weak var owner: CloudReadRequestCoordinator?
        public let key: Key
    }
}
