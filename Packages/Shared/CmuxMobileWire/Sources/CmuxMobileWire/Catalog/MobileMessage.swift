/// One catalog entry: a message, its plane and its single owner.
public struct MobileMessage: Hashable, Sendable, Codable {
    public var name: String
    public var kind: MobileMessageKind
    public var plane: MobilePlane
    public var dir: MobileDirection
    public var owner: String
    /// Channel class, for `channel` messages.
    public var channelClass: ChannelClass?
    /// True when the op already exists in the cloud catalog (its params are the cloud op's).
    public var existing: Bool?
    /// Family error codes beyond the shared ones.
    public var errors: [String]?

    public init(_ name: String, _ kind: MobileMessageKind, _ plane: MobilePlane, _ dir: MobileDirection, owner: String,
                channelClass: ChannelClass? = nil, existing: Bool? = nil, errors: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.plane = plane
        self.dir = dir
        self.owner = owner
        self.channelClass = channelClass
        self.existing = existing
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case name, kind, plane, dir, owner, existing, errors
        case channelClass = "class"
    }
}
