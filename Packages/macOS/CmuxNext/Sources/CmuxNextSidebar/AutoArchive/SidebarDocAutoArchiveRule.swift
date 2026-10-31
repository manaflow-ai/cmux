import Foundation

/// A group's auto-archive rule as the sidebar document stores it (`extra.auto_archive`, the reducer's
/// `AutoArchiveRule`; plans/cmux-next/auto-archive-DESIGN.md "Per-group rules"): its members never
/// archive on their own, or archive after this many idle hours. Absent: the setting decides.
public nonisolated enum SidebarDocAutoArchiveRule: Hashable, Sendable {
    /// The group's members never archive on their own.
    case never
    /// A member idle this many hours archives (1 to 87 600, as the reducer accepts).
    case afterHours(Int)

    /// The longest idle time a rule may name: ten years, in hours (the reducer's bound).
    public static let maxHours = 87_600

    /// The rule a stored value names (`"never"` or a whole number of hours in range); nil otherwise.
    public init?(wire value: Any?) {
        if let text = value as? String, text == "never" {
            self = .never
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == number.doubleValue.rounded(),
                  (1...Self.maxHours).contains(number.intValue) {
            self = .afterHours(number.intValue)
        } else {
            return nil
        }
    }

    /// The value `group.update`'s `auto_archive` patch sends.
    public var wire: Any {
        switch self {
        case .never: "never"
        case let .afterHours(hours): hours
        }
    }

    /// Seconds a member must stay idle; nil for ``never``.
    public var idleSeconds: Double? {
        switch self {
        case .never: nil
        case let .afterHours(hours): Double(hours) * 3600
        }
    }
}
