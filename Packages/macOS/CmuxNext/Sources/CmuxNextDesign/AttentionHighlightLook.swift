public import AppKit
public import CmuxNextDesignTokens

/// How strong the pane attention ring (the notification highlight) draws
/// (Debug Settings `notifications.attention.look`, cx-epgo). Lawrence on the
/// Leo call of 2026-10-09: the highlight must be subtler by default. Every
/// look keeps the user's `notifications.attention.*` style, width and color;
/// it sets only the ring's strength. Lawrence 2026-10-19 (u2414): the ring is
/// the notification blue by default, as the unread dot is. Lawrence 2026-10-10
/// dropped the `foreground` look. A stored `foreground` override is not
/// in the choice list, so TunableStore drops it at load and the look is the
/// `subtle` default.
public nonisolated enum AttentionHighlightLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default. The steady ring (the default style) swells in once and rests clearly
    /// visible; a blink or pulse runs, then the ring rests faint.
    case subtle
    /// The ring flashes and rests at full strength (the look before cx-epgo).
    case strong
    /// The ring flashes, then hides; the tab and the row keep the unread mark.
    case flash

    public var tunableTitle: String {
        switch self {
        case .subtle: "Subtle (faint after the flash)"
        case .strong: "Strong (full ring)"
        case .flash: "Flash only"
        }
    }

    /// The ring's opacity once its animation ends, while it persists.
    public var restingOpacity: Float {
        switch self {
        case .subtle: 0.4
        case .strong: 1
        case .flash: 0
        }
    }

    /// The steady ring's opacity (the default style): clearly visible,
    /// since it has no blink to catch the eye (Leo, 2026-10-14).
    public var steadyOpacity: Float {
        switch self {
        case .subtle: 0.75
        case .strong: 1
        case .flash: 0
        }
    }

    /// The ring's opacity at the peak of a blink or pulse.
    public var peakOpacity: Float {
        switch self {
        case .subtle, .flash: 0.85
        case .strong: 1
        }
    }

    /// The ring color when neither the source nor `notifications.attention.color` sets one: the
    /// theme accent (Leo, 2026-10-21), never a fixed blue. The sidebar's unread dot keeps the
    /// notification blue.
    @MainActor public var defaultColor: NSColor { Palette.accentFill }

    public static let tunable = Tunable<AttentionHighlightLook>.choice(
        "notifications.attention.look", .status, "Notification highlight",
        help: "Strength of the pane attention ring after a notification: subtle (default), strong (the old full ring), flash only (cx-epgo).",
        default: .subtle, code: "AttentionHighlightLook.tunable")
}
