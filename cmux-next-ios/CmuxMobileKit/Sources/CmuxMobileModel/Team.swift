import Foundation

/// A Stack Auth team as the app shows it.
public struct Team: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var appearance: TeamAppearance
    public var macs: [MacDevice]

    /// The account's personal space (PROTOCOL.md "Personal space"): just you,
    /// so it has no invites.
    public var isPersonalSpace: Bool { id.hasPrefix("personal-") }

    public init(id: String, name: String, appearance: TeamAppearance? = nil, macs: [MacDevice] = []) {
        self.id = id
        self.name = name
        self.appearance = appearance ?? TeamAppearance(defaultFor: id)
        self.macs = macs
    }

    /// Up to `limit` dots for the sidebar row, online Macs first, then the overflow count.
    public func macDots(limit: Int = 5) -> (dots: [Bool], overflow: Int) {
        // Online first; stable by name within each group.
        let macs = listedMacs
        let ordered = macs.sorted {
            $0.isOnline != $1.isOnline ? $0.isOnline : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let dots = ordered.prefix(limit).map(\.isOnline)
        return (Array(dots), max(0, macs.count - limit))
    }
}

/// What a team avatar shows over its color.
public enum TeamGlyph: Hashable, Sendable {
    /// The team name's first letter (the default).
    case automatic
    /// One character the user typed: a letter, digit, symbol or emoji.
    case custom(String)
    /// Color only.
    case none

    /// The last grapheme of `input` that is not whitespace, so a field that
    /// already holds a character takes the newest one typed. Nil when there is none.
    public static func character(from input: String) -> String? {
        input.last(where: { !$0.isWhitespace && !$0.isNewline }).map(String.init)
    }
}

/// A team's color and the glyph drawn over it.
///
/// `emoji` is the wire field (`PUT /v1/teams/:teamId/prefs`): nil is
/// automatic (first letter), `""` is none (color only), anything else is one
/// grapheme the user typed. Use `glyph` rather than reading it directly.
///
/// Transparent draws the icon with no filled background. It needs an icon
/// (a custom glyph), so a team always shows an icon or a color: `colorHex`
/// stays set as the fallback, and removing the icon drops transparency and
/// shows that color again.
public struct TeamAppearance: Hashable, Sendable, Codable {
    public var colorHex: String
    public var emoji: String? {
        didSet { if !canBeTransparent { transparent = false } }
    }
    /// The stored flag; read `isTransparent`, which also requires an icon.
    private var transparent: Bool

    public var glyph: TeamGlyph {
        get {
            switch emoji {
            case nil: .automatic
            case let value? where value.isEmpty: .none
            case let value?: .custom(value)
            }
        }
        set {
            switch newValue {
            case .automatic: emoji = nil
            case .none: emoji = ""
            case .custom(let value): emoji = TeamGlyph.character(from: value)
            }
        }
    }

    /// True when the team has an icon the user picked, the only case where
    /// the background can be transparent.
    public var canBeTransparent: Bool {
        if case .custom = glyph { true } else { false }
    }

    /// No filled background behind the icon. Setting it without an icon does nothing.
    public var isTransparent: Bool {
        get { transparent && canBeTransparent }
        set { transparent = newValue && canBeTransparent }
    }

    public init(colorHex: String, emoji: String? = nil, transparent: Bool = false) {
        self.colorHex = colorHex
        self.emoji = emoji
        self.transparent = false
        self.isTransparent = transparent
    }

    /// Picks a palette color: the badge is filled again.
    public mutating func choose(colorHex: String) {
        self.colorHex = colorHex
        transparent = false
    }

    private enum CodingKeys: String, CodingKey { case colorHex, emoji, transparent }

    // Data saved before transparent backgrounds has no `transparent` key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            colorHex: try container.decode(String.self, forKey: .colorHex),
            emoji: try container.decodeIfPresent(String.self, forKey: .emoji),
            transparent: try container.decodeIfPresent(Bool.self, forKey: .transparent) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encode(isTransparent, forKey: .transparent)
    }

    /// A stable color from the palette, so a team keeps its color across launches and devices.
    public init(defaultFor teamID: String) {
        let palette = TeamAppearance.palette
        var hash: UInt64 = 1469598103934665603
        for byte in teamID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        self.init(colorHex: palette[Int(hash % UInt64(palette.count))])
    }

    /// The 13 team colors (SPEC 3.4), stored as their dark-mode `#RRGGBB`.
    public static let palette: [String] = [
        "#FF453A", "#FF9F0A", "#FFD60A", "#30D158", "#63E6E2", "#40CBE0", "#64D2FF",
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#AC8E68", "#8E8E93",
    ]
}

/// A Mac registered to a team.
public struct MacDevice: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var name: String
    public var isOnline: Bool
    public var lastSeenAt: Date?
    /// Who registered the Mac (nil when not known: mock data, older snapshots).
    public var ownerUserID: String?
    /// The computer it runs on (PROTOCOL.md "Devices"): the same for every cmux
    /// build on one Mac, so ``MacRoster`` lists that Mac once. Nil when the Mac
    /// never said (an older host); a name is never used instead.
    public var machineID: String?

    public init(id: String, name: String, isOnline: Bool, lastSeenAt: Date? = nil, ownerUserID: String? = nil,
                machineID: String? = nil) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.ownerUserID = ownerUserID
        self.machineID = machineID
    }
}
