import Foundation

extension DeleteProfileRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var profile: ProfileID
        public var movedTo: ProfileID?
        /// The closed group of a Delete Space; nil for a move or an older daemon.
        public var closedID: String?
        enum CodingKeys: String, CodingKey {
            case profile
            case movedTo = "moved_to"
            case closedID = "closed_id"
        }
    }
}
