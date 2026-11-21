public import Foundation

/// A Cloud network. On NEXT it is the team's: `id` is the team id (what tunnel attach and detach
/// take), `meshId` its provider mesh.
public struct CloudNetwork: Sendable, Hashable, Decodable {
    public var id: String
    public var meshId: String?
    public var cidr: String?
    public var cidrV6: String?
    public var scope: String
}
