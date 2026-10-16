import Foundation

extension CloudReadCooldownStore {
    public struct Cooldown: Sendable {
        public let until: TimeInterval
        public let response: CloudReadRequestCoordinator.Response

        public init(
            until: TimeInterval,
            response: CloudReadRequestCoordinator.Response
        ) {
            self.until = until
            self.response = response
        }
    }
}
