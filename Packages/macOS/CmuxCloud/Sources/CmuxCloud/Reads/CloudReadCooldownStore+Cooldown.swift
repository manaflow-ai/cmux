import Foundation

extension CloudReadCooldownStore {
    public struct Cooldown: Sendable {
        public let until: TimeInterval
        public let response: CloudReadRequestCoordinator.Response
    }
}
