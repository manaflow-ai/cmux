import Foundation

extension SetSessionIconRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var session: SessionRecord
        public var changed: Bool
    }
}
