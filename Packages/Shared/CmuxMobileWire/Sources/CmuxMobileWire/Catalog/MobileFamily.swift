/// A message family with its default plane, owner and stream id pattern.
public struct MobileFamily: Hashable, Sendable, Codable {
    public var name: String
    public var plane: MobilePlane
    public var owner: String
    public var stream: String?
    public var messages: [MobileMessage]

    public init(_ name: String, _ plane: MobilePlane, owner: String, stream: String? = nil, messages: [MobileMessage]) {
        self.name = name
        self.plane = plane
        self.owner = owner
        self.stream = stream
        self.messages = messages
    }
}
