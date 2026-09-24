import Foundation

extension CloudReadCooldownStore {
    struct Cooldown: Sendable {
        let until: TimeInterval
        let response: CloudReadRequestCoordinator.Response
    }
}
