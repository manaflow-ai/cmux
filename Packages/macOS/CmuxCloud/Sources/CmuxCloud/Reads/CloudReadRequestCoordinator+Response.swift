import Foundation

extension CloudReadRequestCoordinator {
    public struct Response: Sendable {
        public let data: Data
        public let http: HTTPURLResponse
    }
}
