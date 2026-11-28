import Foundation

/// A text size a host can set on a conversation, so it can zoom the
/// transcript and composer (the Mac Chief's Zoom In, Zoom Out and Actual
/// Size) without leaving Dynamic Type: each size is one of the system's
/// content size categories, and the conversation lays out exactly as it does
/// when the person picks that size in Settings.
public enum ConversationTextSize: String, CaseIterable, Codable, Sendable, Comparable {
    case extraSmall
    case small
    case medium
    case large
    case extraLarge
    case extraExtraLarge
    case extraExtraExtraLarge
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge
    case accessibilityExtraExtraLarge
    case accessibilityExtraExtraExtraLarge

    /// The system's default size.
    public static let standard = ConversationTextSize.large

    /// Body text at this size, in points (UIKit's body style).
    public var bodyPointSize: Double {
        switch self {
        case .extraSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .extraLarge: 19
        case .extraExtraLarge: 21
        case .extraExtraExtraLarge: 23
        case .accessibilityMedium: 28
        case .accessibilityLarge: 33
        case .accessibilityExtraLarge: 40
        case .accessibilityExtraExtraLarge: 47
        case .accessibilityExtraExtraExtraLarge: 53
        }
    }

    public var isAccessibilitySize: Bool { self >= .accessibilityMedium }

    /// `steps` sizes larger (or smaller, when negative), stopping at the
    /// smallest and largest.
    public func stepped(by steps: Int) -> ConversationTextSize {
        let all = Self.allCases
        return all[min(max(order + steps, 0), all.count - 1)]
    }

    /// This size as a share of `base`, in percent (the Mac's zoom indicator).
    public func percent(of base: ConversationTextSize) -> Int {
        Int((bodyPointSize / base.bodyPointSize * 100).rounded())
    }

    /// Its place among the sizes, smallest first.
    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: ConversationTextSize, rhs: ConversationTextSize) -> Bool {
        lhs.order < rhs.order
    }
}
