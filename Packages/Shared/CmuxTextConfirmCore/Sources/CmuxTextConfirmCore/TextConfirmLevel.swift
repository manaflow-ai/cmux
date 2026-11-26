/// How much Chief confirms in the app before acting on a text.
public enum TextConfirmLevel: String, CaseIterable, Hashable, Sendable, Codable {
    case strict
    case destructiveOnly = "destructive-only"
    case off

    /// Higher is safer.
    var safety: Int {
        switch self {
        case .strict: 2
        case .destructiveOnly: 1
        case .off: 0
        }
    }

    /// Moving from `self` to `other` lowers protection (needs a device proof).
    public func isLowered(to other: TextConfirmLevel) -> Bool { other.safety < safety }
}

/// The level as the owner reports it, with an optional lock (a minimum).
public struct TextConfirmState: Hashable, Sendable {
    public var level: TextConfirmLevel
    /// "Locked by <name>": the owner refuses anything below `lockedLevel`.
    public var lockedBy: String?
    public var lockedLevel: TextConfirmLevel?

    public init(level: TextConfirmLevel = .strict, lockedBy: String? = nil, lockedLevel: TextConfirmLevel? = nil) {
        self.level = level
        self.lockedBy = lockedBy
        self.lockedLevel = lockedLevel
    }

    /// Levels the user can pick (a lock removes the ones below its minimum).
    public var selectable: [TextConfirmLevel] {
        guard let lockedLevel else { return TextConfirmLevel.allCases }
        return TextConfirmLevel.allCases.filter { !lockedLevel.isLowered(to: $0) }
    }
}
