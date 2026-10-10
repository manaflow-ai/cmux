public import CmuxNextIcons
import Foundation

/// The buttons at the trailing end of the browser toolbar, in order, after
/// the pinned extensions (Edge's right side, cx-6qwm): the media hub while a
/// tab plays media, the zoom level while
/// the page is not at 100 %, Favorites, Downloads once this session has
/// downloaded something, then the classic browser pane's
/// design mode, profile, theme, DevTools and More. Each press runs one
/// catalog action (`BrowserToolbarHandlers` in the App), so the palette,
/// the CLI, the socket and the menus share it.
public nonisolated enum BrowserToolbarButton: String, CaseIterable, Hashable, Sendable {
    /// The media hub (`browser.media.show`): what every tab plays, with
    /// its controls. Shown while a tab has media, as in Edge.
    case media
    /// The page's zoom level; a press returns to Actual Size. Shown only
    /// while the page is zoomed, as Edge's address bar does.
    case zoom
    case favorites
    /// The downloads menu (`browser.downloads.show`). Shown once there is
    /// a download to list, as Edge's toolbar does.
    case downloads
    case designMode
    case profile
    case theme
    case devTools
    case overflow

    /// Accessibility identifier (UI automation, `debug.extensions.toolbar`).
    public var identifier: String { "browser.toolbar.\(rawValue)" }

    /// How early the button hides as the pane narrows (`BrowserToolbarButtonsView.collapse`):
    /// design mode and DevTools at level 1, the rest at level 2; More always
    /// stays and lists the hidden ones.
    public var collapseLevel: Int? {
        switch self {
        case .designMode, .devTools: 1
        case .media, .zoom, .favorites, .downloads, .profile, .theme: 2
        case .overflow: nil
        }
    }

    /// Whether the button is hidden at collapse `level`.
    public func isCollapsed(at level: Int) -> Bool { collapseLevel.map { $0 <= level } ?? false }

    /// Whether the button shows at collapse `level`: the media hub only
    /// while a tab has media, zoom only while the page is zoomed, Downloads
    /// only once there is a download.
    public func isShown(at level: Int, _ facts: BrowserToolbarFacts) -> Bool {
        guard !isCollapsed(at: level) else { return false }
        switch self {
        case .media: return facts.media.sessions > 0
        case .zoom: return BrowserZoom.percent(facts.zoom) != 100
        case .downloads: return facts.downloads.count > 0
        default: return true
        }
    }
}

/// What one toolbar button shows.
public nonisolated struct BrowserToolbarButtonState: Hashable, Sendable {
    public var icon: IconName
    /// Tooltip and accessibility label; the reason when disabled.
    public var label: String
    public var isEnabled: Bool
    /// Drawn in the accent color (design mode on, DevTools open).
    public var isActive: Bool

    public init(icon: IconName, label: String, isEnabled: Bool = true, isActive: Bool = false) {
        self.icon = icon
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
    /// The page's zoom factor, 1.0 = 100 %.
    public var zoom: Double
    /// The App's downloads, every tab's.
    public var downloads: BrowserToolbarDownloads
    /// Media in every tab.
    public var media: BrowserToolbarMedia

    public init(engine: BrowserEngineKind, hostsDevTools: Bool, devToolsOpen: Bool = false, designMode: Bool = false,
                colorScheme: BrowserColorScheme = .system, profileName: String? = nil, zoom: Double = 1,
                downloads: BrowserToolbarDownloads = BrowserToolbarDownloads(), media: BrowserToolbarMedia = BrowserToolbarMedia()) {
        self.engine = engine
        self.hostsDevTools = hostsDevTools
        self.devToolsOpen = devToolsOpen
        self.designMode = designMode
        self.colorScheme = colorScheme
        self.profileName = profileName
        self.zoom = zoom
        self.downloads = downloads
        self.media = media
    }
}

