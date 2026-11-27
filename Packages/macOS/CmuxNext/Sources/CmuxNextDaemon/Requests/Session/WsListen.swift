import Foundation

extension WsListenRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var url: String
        public var pages: String?
        /// False when the listener already existed.
        public var opened: Bool
    }
}
