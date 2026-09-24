import Foundation

extension CloudReadRequestCoordinator {
    struct Context: Sendable {
        weak var owner: CloudReadRequestCoordinator?
        let key: Key
    }
}
