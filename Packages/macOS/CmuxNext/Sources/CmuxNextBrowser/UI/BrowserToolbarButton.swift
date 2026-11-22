import Foundation

/// The five buttons at the trailing end of the browser toolbar, in order
/// (the classic browser pane's design mode, profile, theme, DevTools and
/// More). Each press runs one catalog action (`BrowserToolbarRouter` in
/// the App), so the palette, the CLI, the socket and the menus share it.
public nonisolated enum BrowserToolbarButton: String, CaseIterable, Hashable, Sendable {
    case designMode
    case profile
    case theme
    case devTools
    case overflow

    /// Accessibility identifier (UI automation, `debug.extensions.toolbar`).
    public var identifier: String { "browser.toolbar.\(rawValue)" }

    /// How early the button hides as the pane narrows (`BrowserToolbarButtonsView.collapse`):
    /// design mode and DevTools at level 1, profile and theme at level 2;
    /// More always stays and lists the hidden ones.
    public var collapseLevel: Int? {
        switch self {
        case .designMode, .devTools: 1
        case .profile, .theme: 2
        case .overflow: nil
        }
    }

    /// Whether the button is hidden at collapse `level`.
    public func isCollapsed(at level: Int) -> Bool { collapseLevel.map { $0 <= level } ?? false }
}

/// What one toolbar button shows.
public nonisolated struct BrowserToolbarButtonState: Hashable, Sendable {
    public var symbol: String
    /// Tooltip and accessibility label; the reason when disabled.
    public var label: String
    public var isEnabled: Bool
    /// Drawn in the accent color (design mode on, DevTools open).
    public var isActive: Bool

    public init(symbol: String, label: String, isEnabled: Bool = true, isActive: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.isEnabled = isEnabled
        self.isActive = isActive
    }
}

/// Facts about the tab that decide the buttons' states.
public nonisolated struct BrowserToolbarFacts: Hashable, Sendable {
    public var engine: BrowserEngineKind
    /// A live page whose engine hosts DevTools (a running Chromium tab), or
    /// WebKit's inspector.
    public var hostsDevTools: Bool
    public var devToolsOpen: Bool
    public var designMode: Bool
    public var colorScheme: BrowserColorScheme
    /// The tab's browser profile name, when known.
    public var profileName: String?

    public init(engine: BrowserEngineKind, hostsDevTools: Bool, devToolsOpen: Bool = false, designMode: Bool = false,
                colorScheme: BrowserColorScheme = .system, profileName: String? = nil) {
        self.engine = engine
        self.hostsDevTools = hostsDevTools
        self.devToolsOpen = devToolsOpen
        self.designMode = designMode
        self.colorScheme = colorScheme
        self.profileName = profileName
    }
}
