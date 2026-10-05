public import AppKit

/// The color scheme a page sees (`prefers-color-scheme`), chosen per tab
/// with the toolbar's theme button or `browserTheme`.
public nonisolated enum BrowserColorScheme: String, CaseIterable, Hashable, Sendable {
    /// Follows the app's appearance.
    case system
    case light
    case dark

    /// The SF Symbol the toolbar's theme button shows for this scheme.
    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// A tab whose engine can force a page's color scheme. WebKit follows its
/// view's appearance; Chromium takes a DevTools media emulation.
@MainActor
public protocol BrowserColorSchemeApplying: AnyObject {
    func applyColorScheme(_ scheme: BrowserColorScheme)
}

extension WebKitTab: BrowserColorSchemeApplying {
    /// In-view WebKit pages follow the view's appearance for
    /// `prefers-color-scheme`; nil follows the app.
    public func applyColorScheme(_ scheme: BrowserColorScheme) {
        contentView.appearance = switch scheme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension MockBrowserTab: BrowserColorSchemeApplying {
    public func applyColorScheme(_ scheme: BrowserColorScheme) { record(.applyColorScheme(scheme)) }
}
