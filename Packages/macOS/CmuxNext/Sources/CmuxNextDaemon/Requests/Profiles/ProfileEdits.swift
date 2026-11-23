import Foundation

/// Deletes a room. With `moveTo` its pins and groups move there. Without
/// it this is Delete Space (SPACE-DELETE-CLOSES-ITS-WORKSPACES): the daemon
/// closes every workspace of its session that only this room shows and
/// records the room and them as one closed group (`closedID`), which
/// `closed.reopen` restores. Workspaces of other sessions only lose their
/// pin. The daemon refuses `default`.
public struct DeleteProfileRequest: DaemonRequest {
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
    public static let command = "delete-profile"
    public static let requiredCapability: String? = DaemonCapability.profiles.rawValue
    public var profile: ProfileID
    public var moveTo: ProfileID?
    public init(profile: ProfileID, moveTo: ProfileID? = nil) {
        self.profile = profile
        self.moveTo = moveTo
    }
}
