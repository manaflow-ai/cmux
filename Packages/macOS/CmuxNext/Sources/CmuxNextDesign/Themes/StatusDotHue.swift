public import CmuxNextDesignTokens

/// A status mark whose hue means one thing in every row (Lawrence msg 11983: "blue, orange/yellow
/// for needs attention, and red for errors").
///
/// The hue stays; its lightness moves per theme until the mark reaches 3:1 on the rows it sits on
/// (``ThemeTokens/statusDot(_:)``). The system colors alone read 1.7:1 (orange on every light
/// theme) and 1.4:1 (blue on Blue Dolphin). Needs attention starts from the theme's own yellow
/// (``ThemeTokens/attention``), the bright dot the tab strip draws (Leo 2026-11-05: "What if we
/// try that yellow dot thing that we currently have in the horizontal tab and put that in the
/// sidebar?").
public enum StatusDotHue: CaseIterable, Sendable {
    /// Unread or new (`systemBlue`).
    case unread
    /// Needs attention: a permission prompt, a question. In a theme, the theme's yellow
    /// (``ThemeTokens/attention``); `systemYellow` only where no theme resolves.
    case attention
    /// Failed or stopped with an error (`systemRed`).
    case error
    /// The notification blue (rgb 57 130 245, sampled from the Codex app): unread dots and tab badges.
    case notification

    /// The mark's starting color in a light or a dark theme: the system color's light or dark value.
    /// ``ThemeTokens/statusDot(_:)`` starts `attention` from the theme's yellow instead.
    public func hue(isDark: Bool) -> ThemeRGB {
        switch self {
        case .unread: isDark ? ThemeRGB(r: 10, g: 132, b: 255) : ThemeRGB(r: 0, g: 122, b: 255)
        case .attention: isDark ? ThemeRGB(r: 255, g: 214, b: 10) : ThemeRGB(r: 255, g: 204, b: 0)
        case .error: isDark ? ThemeRGB(r: 255, g: 69, b: 58) : ThemeRGB(r: 255, g: 59, b: 48)
        case .notification: ThemeRGB(r: 57, g: 130, b: 245)
        }
    }
}
