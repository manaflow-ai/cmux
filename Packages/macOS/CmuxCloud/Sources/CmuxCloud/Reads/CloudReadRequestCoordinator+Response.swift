import Foundation

extension CloudReadRequestCoordinator {
    public struct Response: Sendable {
        public let data: Data
        public let http: HTTPURLResponse

        public init(
            data: Data,
            http: HTTPURLResponse
        ) {
            self.data = data
            self.http = http
        }
    }
}
