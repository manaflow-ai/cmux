import Foundation

extension CloudReadRequestCoordinator {
    struct Response: Sendable {
        let data: Data
        let http: HTTPURLResponse
    }
}
