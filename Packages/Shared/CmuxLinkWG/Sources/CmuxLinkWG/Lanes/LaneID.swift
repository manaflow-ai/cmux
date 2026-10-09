import CmuxLink

/// One lane inside the tunnel: a delivery class and a priority. Encoded in
/// one byte, `kind << 4 | priority`.
struct LaneID: Hashable {
    enum Kind: UInt8 {
        case reliable = 0
        case unordered = 1
        case partial = 2
    }

    let kind: Kind
    let priority: ChannelPriority

    init(kind: Kind, priority: ChannelPriority) {
        self.kind = kind
        self.priority = priority
    }

    init(_ lane: TransportLane) {
        switch lane.reliability {
        case .reliableOrdered: kind = .reliable
        case .unreliableUnordered: kind = .unordered
        case .partial: kind = .partial
        }
        priority = lane.priority
    }

    init?(byte: UInt8) {
        guard let kind = Kind(rawValue: byte >> 4), let priority = ChannelPriority(rawValue: Int(byte & 0x0F)) else { return nil }
        self.init(kind: kind, priority: priority)
    }

    var byte: UInt8 { kind.rawValue << 4 | UInt8(priority.rawValue) }
}
