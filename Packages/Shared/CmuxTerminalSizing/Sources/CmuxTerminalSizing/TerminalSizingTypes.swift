import Foundation

/// A terminal grid in cells.
public struct TerminalGridSize: Codable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// The same grid clamped to the smallest size a host applies (2 × 1).
    public var clamped: TerminalGridSize {
        TerminalGridSize(cols: max(2, cols), rows: max(1, rows))
    }
}

/// The kind of device behind one attached view.
public enum TerminalDeviceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case mac, iphone, ipad, tui, browser, unknown

    /// Phones and tablets defer to a Mac or TUI of the same user.
    public var isHandheld: Bool { self == .iphone || self == .ipad }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TerminalDeviceKind(rawValue: raw) ?? .unknown
    }
}

/// One attached view of a terminal, as the host sees it.
public struct TerminalSizingParticipant: Codable, Hashable, Sendable, Identifiable {
    /// Host-scoped id, unique while attached.
    public var id: String
    /// Verified Stack user id, set by the host or relay and never by the viewer.
    public var userID: String?
    public var displayName: String?
    public var deviceKind: TerminalDeviceKind
    public var deviceName: String?
    /// Stable per-install id of the device (one Mac app install, one phone
    /// install, one cmux-tui host). Tells two Macs of the same user apart.
    public var deviceID: String?
    /// Participant id of the relay that forwards this view, if any.
    public var via: String?
    /// Last reported viewport; nil until the viewer reports one.
    public var viewport: TerminalGridSize?
    /// Explicit counts-toward-size choice; nil means the automatic rule.
    public var countsOverride: Bool?

    public init(
        id: String,
        userID: String? = nil,
        displayName: String? = nil,
        deviceKind: TerminalDeviceKind,
        deviceName: String? = nil,
        deviceID: String? = nil,
        via: String? = nil,
        viewport: TerminalGridSize? = nil,
        countsOverride: Bool? = nil
    ) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.deviceKind = deviceKind
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.via = via
        self.viewport = viewport?.clamped
        self.countsOverride = countsOverride
    }

    /// Stable key used by priority lists:
    /// `<user_id or anon:id>/<device_kind>/<device_id>`, or the legacy
    /// `<user_id or anon:id>/<device_kind>` when the device has no id.
    public var priorityKey: String {
        guard let deviceID, !deviceID.isEmpty else { return legacyPriorityKey }
        return "\(legacyPriorityKey)/\(deviceID)"
    }

    /// The two-segment key older policies stored. A policy entry in this form
    /// matches every device of that kind for that user.
    public var legacyPriorityKey: String {
        "\(userID ?? "anon:\(id)")/\(deviceKind.rawValue)"
    }

    /// Whether a priority list entry names this participant: its own key, or
    /// the legacy key of its user and device kind.
    public func matchesPriorityKey(_ key: String) -> Bool {
        key == priorityKey || key == legacyPriorityKey
    }

    enum CodingKeys: String, CodingKey {
        case id, via, viewport
        case userID = "user_id"
        case displayName = "display_name"
        case deviceKind = "device_kind"
        case deviceName = "device_name"
        case deviceID = "device_id"
        case countsOverride = "counts_override"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(deviceKind, forKey: .deviceKind)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(via, forKey: .via)
        try c.encode(viewport, forKey: .viewport)
        try c.encode(countsOverride, forKey: .countsOverride)
    }
}

/// How the host picks the grid.
public enum TerminalSizingMode: String, Codable, Hashable, Sendable, CaseIterable {
    case latest, smallest, largest, priority, fixed
}

/// A sizing policy for one terminal or a workspace default.
public struct TerminalSizingPolicy: Codable, Hashable, Sendable {
    public var mode: TerminalSizingMode
    /// Priority keys, highest first. Used by `.priority`.
    public var priority: [String]
    /// Grid used by `.fixed`.
    public var fixed: TerminalGridSize?

    public init(mode: TerminalSizingMode = .smallest, priority: [String] = [], fixed: TerminalGridSize? = nil) {
        self.mode = mode
        self.priority = priority
        self.fixed = fixed?.clamped
    }

    /// The default: fit everyone, so every attached device sees the whole grid.
    public static let fitEveryone = TerminalSizingPolicy(mode: .smallest)

    public static let latest = TerminalSizingPolicy(mode: .latest)

    /// The largest fixed grid a client may request. Every entrypoint (size
    /// panel, socket, phone) enforces it, so no host receives a grid its
    /// wire types cannot carry.
    public static let maximumFixedSize = TerminalGridSize(cols: 500, rows: 200)

    /// Whether ``fixed`` is absent or within ``maximumFixedSize``.
    public var fixedSizeIsWithinLimit: Bool {
        guard let fixed else { return true }
        return fixed.cols <= Self.maximumFixedSize.cols && fixed.rows <= Self.maximumFixedSize.rows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try c.decodeIfPresent(TerminalSizingMode.self, forKey: .mode) ?? .smallest,
            priority: try c.decodeIfPresent([String].self, forKey: .priority) ?? [],
            fixed: try c.decodeIfPresent(TerminalGridSize.self, forKey: .fixed)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(priority, forKey: .priority)
        try c.encode(fixed, forKey: .fixed)
    }

    enum CodingKeys: String, CodingKey { case mode, priority, fixed }
}

/// Why the grid has its current size.
public enum TerminalSizingReason: String, Codable, Hashable, Sendable {
    case latest, smallest, largest, priority, fixed, held
    case priorityFallback = "priority-fallback"
}

/// One participant row of a published size state.
public struct TerminalSizingParticipantState: Codable, Hashable, Sendable, Identifiable {
    public var participant: TerminalSizingParticipant
    /// Whether the participant counts toward size right now.
    public var counts: Bool

    public var id: String { participant.id }
    public var priorityKey: String { participant.priorityKey }

    public init(participant: TerminalSizingParticipant, counts: Bool) {
        self.participant = participant
        self.counts = counts
    }

    enum ExtraKeys: String, CodingKey {
        case counts
        case priorityKey = "priority_key"
    }

    public init(from decoder: any Decoder) throws {
        participant = try TerminalSizingParticipant(from: decoder)
        counts = try decoder.container(keyedBy: ExtraKeys.self).decode(Bool.self, forKey: .counts)
    }

    public func encode(to encoder: any Encoder) throws {
        try participant.encode(to: encoder)
        var c = encoder.container(keyedBy: ExtraKeys.self)
        try c.encode(counts, forKey: .counts)
        try c.encode(priorityKey, forKey: .priorityKey)
    }
}

/// The state a host publishes to every viewer. Same JSON on every host.
public struct TerminalSizingState: Codable, Hashable, Sendable {
    public var generation: UInt64
    public var cols: Int
    public var rows: Int
    public var reason: TerminalSizingReason
    /// Participants that set a dimension, in attach order.
    public var owners: [String]
    public var policy: TerminalSizingPolicy
    public var participants: [TerminalSizingParticipantState]

    public init(
        generation: UInt64,
        cols: Int,
        rows: Int,
        reason: TerminalSizingReason,
        owners: [String],
        policy: TerminalSizingPolicy,
        participants: [TerminalSizingParticipantState]
    ) {
        self.generation = generation
        self.cols = cols
        self.rows = rows
        self.reason = reason
        self.owners = owners
        self.policy = policy
        self.participants = participants
    }

    public var size: TerminalGridSize { TerminalGridSize(cols: cols, rows: rows) }

    public func participant(_ id: String) -> TerminalSizingParticipantState? {
        participants.first { $0.id == id }
    }

    /// The single owner, when exactly one participant sets both dimensions.
    public var soleOwner: TerminalSizingParticipantState? {
        owners.count == 1 ? participant(owners[0]) : nil
    }
}

/// Who disconnected a view.
public struct TerminalDetachActor: Codable, Hashable, Sendable {
    public var userID: String?
    public var displayName: String?
    public var deviceName: String?

    public init(userID: String? = nil, displayName: String? = nil, deviceName: String? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.deviceName = deviceName
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case deviceName = "device_name"
    }
}

/// Why a view was detached. Decoded from `detached {reason, by}`.
public enum TerminalDetachReason: Hashable, Sendable {
    case network
    case disconnectedBy(TerminalDetachActor?)
    case hostShutdown
    case superseded

    /// Only a network drop reconnects without the user asking.
    public var reconnectsAutomatically: Bool {
        if case .network = self { return true }
        return false
    }

    public var wireValue: String {
        switch self {
        case .network: "network"
        case .disconnectedBy: "disconnected-by"
        case .hostShutdown: "host-shutdown"
        case .superseded: "superseded"
        }
    }

    /// Parses the wire `reason` and optional `by`. Unknown or absent reasons are
    /// treated as `network`, which keeps today's reconnect behavior.
    public init(wireValue: String?, by: TerminalDetachActor?) {
        switch wireValue {
        case "disconnected-by": self = .disconnectedBy(by)
        case "host-shutdown": self = .hostShutdown
        case "superseded": self = .superseded
        default: self = .network
        }
    }
}
