public import AppKit

/// How strong the pane attention ring (the notification highlight) draws
/// (Debug Settings `notifications.attention.look`, cx-epgo). Lawrence on the
/// Leo call of 2026-10-09: the highlight must be subtler by default. Every
/// look keeps the user's `notifications.attention.*` style, width and color;
/// it sets only the ring's strength. No look is blue. Lawrence 2026-10-10
/// dropped the `foreground` look; a stored `foreground` reads as `subtle`.
public nonisolated enum AttentionHighlightLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The style's animation runs (a blink by default), then the ring rests
    /// faint (the default). Steady and Reduce Motion fade in to the faint ring.
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

    /// The ring's opacity at the peak of a blink or pulse.
    public var peakOpacity: Float {
        switch self {
        case .subtle, .flash: 0.85
        case .strong: 1
        }
    }

    /// The ring color when neither the source nor `notifications.attention.color` sets one.
    @MainActor public var defaultColor: NSColor { Palette.attention }

    /// Decodes a stored override. `foreground` (a look removed 2026-10-10)
    /// maps to `subtle`, so an old Debug Settings value keeps working.
    public init?(tunableValue: TunableValue) {
        guard let raw = tunableValue.choice else { return nil }
        if raw == "foreground" {
            self = .subtle
            return
        }
        guard let value = Self(rawValue: raw) else { return nil }
        self = value
    }

    public static let tunable = Tunable<AttentionHighlightLook>.choice(
        "notifications.attention.look", .status, "Notification highlight",
        help: "Strength of the pane attention ring after a notification: subtle (default), strong (the old full ring), flash only (cx-epgo).",
        default: .subtle, code: "AttentionHighlightLook.tunable")
}
