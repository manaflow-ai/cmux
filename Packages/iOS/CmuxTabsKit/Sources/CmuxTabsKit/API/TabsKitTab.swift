import Foundation

/// One tab as the kit shows it: a card in the grid, a page behind the
/// toolbar, and the toolbar's address capsule. The client builds these from
/// its own model; the kit never stores them.
public struct TabsKitTab: Identifiable, Hashable, Sendable {
    public typealias ID = String

    public var id: ID
    /// What the tab is (web page, terminal, note, ...). The kit only uses it
    /// to pass back to the client; content, cards and menus come from the
    /// data source.
    public var kind: TabsKitTabKind
    /// Card title and accessibility name.
    public var title: String
    /// Secondary text (URL, host, working directory). Shown by the default
    /// address suggestions.
    public var subtitle: String
    /// SF Symbol for the card's title row and the default card placeholder.
    public var systemImage: String
    /// What the toolbar's address capsule shows for this tab.
    public var address: TabsKitAddress
    /// Back/forward and loading state for the toolbar.
    public var navigation: TabsKitNavigationState
    /// Which toolbar controls the tab offers.
    public var features: TabsKitTabFeatures
    /// Status bar style while the tab is on screen (nil: follow the
    /// appearance). For a web page use `TabsKitStatusBarStyle(over:)` with
    /// the page's top color.
    public var statusBarStyle: TabsKitStatusBarStyle?

    public init(id: ID, kind: TabsKitTabKind, title: String, subtitle: String = "", systemImage: String = "globe",
                address: TabsKitAddress, navigation: TabsKitNavigationState = TabsKitNavigationState(),
                features: TabsKitTabFeatures = .web, statusBarStyle: TabsKitStatusBarStyle? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.address = address
        self.navigation = navigation
        self.features = features
        self.statusBarStyle = statusBarStyle
    }
}

/// An open set of tab kinds. Define your own with `TabsKitTabKind("note")`.
public struct TabsKitTabKind: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let web = TabsKitTabKind("web")
    public static let terminal = TabsKitTabKind("terminal")
}

/// The address capsule's content.
public enum TabsKitAddress: Hashable, Sendable {
    /// A page with an address. `display` is the short label (usually the
    /// host); `editingText` is what the field holds when editing starts (the
    /// full URL). `isSearch` adds the magnifying glass (a search results page).
    case url(display: String, editingText: String, isSearch: Bool = false)
    /// An empty page (a new tab's start page): a dimmed placeholder with a
    /// magnifying glass; tapping it starts editing with an empty field.
    case placeholder(String)
    /// A page without an address (a terminal, a note): title over an
    /// optional subtitle. Tapping it opens the page menu.
    case title(String, subtitle: String = "", monospaced: Bool = false)

    /// The label text the capsule shows (and the collapsed pill hugs).
    public var label: String {
        switch self {
        case .url(let display, _, _): display
        case .placeholder(let text): text
        case .title(let title, _, _): title
        }
    }
}

/// Back/forward and loading state.
public struct TabsKitNavigationState: Hashable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    /// Load progress 0...1 (the progress line along the capsule).
    public var progress: Double
    /// The content is zoomed in past its minimum zoom. A slow pinch-in then
    /// zooms the content instead of opening the tab grid.
    public var isZoomedIn: Bool

    public init(canGoBack: Bool = false, canGoForward: Bool = false, isLoading: Bool = false, progress: Double = 1, isZoomedIn: Bool = false) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.progress = progress
        self.isZoomedIn = isZoomedIn
    }
}

/// Toolbar controls a tab offers.
public struct TabsKitTabFeatures: OptionSet, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Back | forward capsule.
    public static let history = TabsKitTabFeatures(rawValue: 1 << 0)
    /// Reload / stop at the capsule's trailing end.
    public static let reload = TabsKitTabFeatures(rawValue: 1 << 1)
    /// Tapping the address edits it (`TabsDataSource.navigate`).
    public static let addressEditing = TabsKitTabFeatures(rawValue: 1 << 2)
    /// The page menu glyph at the capsule's leading end.
    public static let pageMenu = TabsKitTabFeatures(rawValue: 1 << 3)

    /// Everything a web page has.
    public static let web: TabsKitTabFeatures = [.history, .reload, .addressEditing, .pageMenu]
}

/// Status bar content style a tab asks for.
public enum TabsKitStatusBarStyle: String, Hashable, Sendable {
    /// Dark clock and icons, for light content under the status bar.
    case darkContent
    /// Light clock and icons, for dark content under the status bar.
    case lightContent
}

/// An entry of the (+) button: one option is a plain button, several make
/// it a menu. The first option is also what a toolbar swipe past the last
/// tab and closing the last tab create.
public struct TabsKitNewTabOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var kind: TabsKitTabKind

    public init(id: String, title: String, systemImage: String, kind: TabsKitTabKind) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
    }
}

/// One row of the page menu.
public struct TabsKitMenuItem: Identifiable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var isEnabled: Bool
    public var isDestructive: Bool
    /// Runs after the menu starts closing.
    public var action: @MainActor () -> Void

    public init(id: String? = nil, title: String, systemImage: String, isEnabled: Bool = true, isDestructive: Bool = false,
                action: @escaping @MainActor () -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// Direction of a back/forward history list.
public enum TabsKitHistoryDirection: Hashable, Sendable {
    case back
    case forward
}

/// One entry of the back/forward long-press menu.
public struct TabsKitHistoryItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}
