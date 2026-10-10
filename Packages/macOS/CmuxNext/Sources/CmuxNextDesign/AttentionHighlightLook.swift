public import AppKit

/// How strong the pane attention ring (the notification highlight) draws
/// (Debug Settings `notifications.attention.look`, cx-epgo). Lawrence on the
/// Leo call of 2026-10-09: the highlight must be subtler by default. Every
/// look keeps the user's `notifications.attention.*` style, width and color;
/// it sets only the ring's strength, and `foreground` swaps the default theme
/// yellow for the theme's foreground. No look is blue.
public nonisolated enum AttentionHighlightLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The ring flashes at full strength, then rests faint (the default).
    case subtle
    /// The ring flashes and rests at full strength (the look before cx-epgo).
    case strong
    /// Like `subtle`, in the theme's foreground instead of its yellow.
    case foreground
    /// The ring flashes, then hides; the tab and the row keep the unread mark.
    case flash

    public var tunableTitle: String {
        switch self {
        case .subtle: "Subtle (faint after the flash)"
        case .strong: "Strong (full ring)"
        case .foreground: "Foreground (theme text color, faint)"
        case .flash: "Flash only"
        }
    }

    /// The ring's opacity once its animation ends, while it persists.
    public var restingOpacity: Float {
        switch self {
        case .subtle, .foreground: 0.4
        case .strong: 1
        case .flash: 0
        }
    }

    /// The ring's opacity at the peak of a blink or pulse.
    public var peakOpacity: Float {
        switch self {
        case .subtle, .foreground, .flash: 0.85
        case .strong: 1
        }
    }

    /// The ring color when neither the source nor `notifications.attention.color` sets one.
    @MainActor public var defaultColor: NSColor {
        switch self {
        case .foreground: Palette.textSecondary
        case .subtle, .strong, .flash: Palette.attention
        }
    }

    public static let tunable = Tunable<AttentionHighlightLook>.choice(
        "notifications.attention.look", .status, "Notification highlight",
        help: "Strength of the pane attention ring after a notification: subtle (default), strong (the old full ring), foreground, flash only (cx-epgo).",
        default: .subtle, code: "AttentionHighlightLook.tunable")
}
