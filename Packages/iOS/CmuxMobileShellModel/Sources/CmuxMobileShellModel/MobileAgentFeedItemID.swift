/// Stable cross-Mac identity for one coding-agent event.
public struct MobileAgentFeedItemID: Hashable, Comparable, Sendable {
    public let macDeviceID: String
    public let macInstanceTag: String?
    public let eventID: String

    public init(macDeviceID: String, macInstanceTag: String?, eventID: String) {
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.eventID = eventID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.macDeviceID != rhs.macDeviceID { return lhs.macDeviceID < rhs.macDeviceID }
        if lhs.macInstanceTag != rhs.macInstanceTag { return (lhs.macInstanceTag ?? "") < (rhs.macInstanceTag ?? "") }
        return lhs.eventID < rhs.eventID
    }
}
