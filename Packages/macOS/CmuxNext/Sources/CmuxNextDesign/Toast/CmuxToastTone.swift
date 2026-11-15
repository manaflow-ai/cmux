public import AppKit

/// What a toast says about how things went, which styles that mark it show (``CmuxToastLook/showsIcon``,
/// ``CmuxToastLook/accentBar``): plain news, a success, a warning or an error.
public nonisolated enum CmuxToastTone: String, Sendable, CaseIterable {
    /// Plain news or a hint.
    case neutral
    /// Something the person asked for worked.
    case success
    /// Something needs a look (a restart after a problem, low disk).
    case warning
    /// Something failed or was refused.
    case error

    /// The SF Symbol a style with an icon shows for the tone.
    public var symbolName: String {
        switch self {
        case .neutral: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    /// The tone's color in the theme in effect: the accent for news, else the theme's status colors.
    @MainActor public var color: NSColor {
        switch self {
        case .neutral: Palette.accentFill
        case .success: Palette.success
        case .warning: Palette.attention
        case .error: Palette.danger
        }
    }
}
