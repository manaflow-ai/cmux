public import CmuxNextIcons
import Foundation

/// The buttons at the trailing end of the browser toolbar, in order, after
/// the pinned extensions (cx-6qwm): the media hub while a
/// tab plays media, the zoom level while
/// the page is not at 100 %, Favorites, Downloads once this session has
/// downloaded something, then the classic browser pane's
/// design mode, profile, theme, DevTools and More. Each press runs one
/// catalog action (`BrowserToolbarHandlers` in the App), so the palette,
/// the CLI, the socket and the menus share it.
///
/// Only pinned buttons show (cx-d0d.81, `browser.toolbarButtons`): by default
/// the media hub, zoom and Downloads, each only while it has something to
/// show, so a page shows Back, Forward, Reload, the address bar and More.
/// The rest are rows of the More menu, whose Show in Toolbar items pin them.
public nonisolated enum BrowserToolbarButton: String, CaseIterable, Hashable, Sendable {
    /// The media hub (`browser.media.show`): what every tab plays, with
    /// its controls. Shown while a tab has media, as in Edge.
    case media
    /// The page's zoom level; a press returns to Actual Size. Shown only
    /// while the page is zoomed, as Edge's address bar does.
    case zoom
    case favorites
    /// The downloads menu (`browser.downloads.show`). Shown once the tab
    /// started a download in this run, or while any download runs, as
    /// Chrome's toolbar does; never for downloads kept from an earlier run.
    case downloads
    case designMode
    case profile
    case theme
    case devTools
    case overflow

    /// A press opens a menu or popover (media, Downloads, profile, theme,
    /// More), so a right-click presses it too (cx-2lm4). Zoom resets and
    /// the toggles toggle, so a right-click leaves them alone.
    public var opensMenu: Bool {
        switch self {
        case .media, .downloads, .profile, .theme, .overflow: true
        case .zoom, .favorites, .designMode, .devTools: false
        }
    }

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

    /// Whether a person can pin or unpin it (More always shows).
    public var isPinnable: Bool { self != .overflow }

    /// The buttons a person can pin, in toolbar order.
    public static var pinnable: [BrowserToolbarButton] { allCases.filter(\.isPinnable) }

    /// Whether the button has something to show: the media hub only while a
    /// tab has media, zoom only while the page is zoomed, Downloads only once
    /// the tab downloaded something or while a download runs.
    public func hasContent(_ facts: BrowserToolbarFacts) -> Bool {
        switch self {
        case .media: facts.media.sessions > 0
        case .zoom: BrowserZoom.percent(facts.zoom) != 100
        case .downloads: facts.downloads.count > 0 || facts.downloads.inProgress
        default: true
        }
    }

    /// Whether the button shows at collapse `level`: pinned (More always),
    /// not collapsed, and with something to show.
    public func isShown(at level: Int, _ facts: BrowserToolbarFacts, pinned: Set<BrowserToolbarButton>) -> Bool {
        guard !isPinnable || pinned.contains(self) else { return false }
        return !isCollapsed(at: level) && hasContent(facts)
    }

    /// The Show in Toolbar item's title.
    public var pinTitle: String {
        switch self {
        case .media: Strings.toolbarMedia
        case .zoom: Strings.toolbarPinZoom
        case .favorites: Strings.toolbarFavorites
        case .downloads: Strings.toolbarDownloads
        case .designMode: Strings.toolbarDesignMode
        case .profile: Strings.toolbarProfileUnknown
        case .theme: Strings.toolbarPinTheme
        case .devTools: Strings.toolbarPinDevTools
        case .overflow: Strings.toolbarMore
        }
    }

    /// The More menu's Show in Toolbar submenu title.
    public static var showInToolbarTitle: String { Strings.toolbarShowInToolbar }
}

/// What one toolbar button shows.
public nonisolated struct BrowserToolbarButtonState: Hashable, Sendable {
    public var icon: IconName
    /// Tooltip and accessibility label; the reason when disabled.
    public var label: String
    public var isEnabled: Bool
    /// Drawn in the accent color (design mode on, DevTools open).
    public var isActive: Bool
    /// Hover shows `label` as a tooltip (`BrowserToolbarPolicy.toolTipInforms`).
    public var showsToolTip = true
    /// A progress ring around the icon (Downloads while one runs): 0...1, or
    /// a negative value for a running download of unknown size; nil draws none.
    public var progress: Double?

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
    /// The tab's downloads of this run (`count`) and whether any download runs.
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

