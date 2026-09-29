import Foundation

// Data the App fills from daemon state. Feature modules never import the
// daemon; the App adapts its models to these small protocols.

public struct PaletteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var directory: String?
    public var isSelected: Bool
    public var unreadCount: Int

    public init(id: String, title: String, directory: String? = nil, isSelected: Bool = false, unreadCount: Int = 0) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.unreadCount = unreadCount
    }
}

public protocol PaletteWorkspaceSource: AnyObject {
    var workspaces: [PaletteWorkspace] { get }
    func selectWorkspace(id: String)
    func renameWorkspace(id: String, to title: String)
    func closeWorkspace(id: String)
}

public struct PaletteTab: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case terminal
        case browser
        case other(symbol: String)
    }

    public let id: String
    public var title: String
    public var workspaceTitle: String?
    public var kind: Kind
    public var isSelected: Bool

    public init(id: String, title: String, workspaceTitle: String? = nil, kind: Kind = .terminal, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.workspaceTitle = workspaceTitle
        self.kind = kind
        self.isSelected = isSelected
    }
}

public protocol PaletteTabSource: AnyObject {
    var tabs: [PaletteTab] { get }
    func selectTab(id: String)
    func renameTab(id: String, to title: String)
    func closeTab(id: String)
}

public struct PaletteOpenInApp: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var symbol: String

    public init(id: String, name: String, symbol: String = "app") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

public protocol PaletteOpenInSource: AnyObject {
    var apps: [PaletteOpenInApp] { get }
    /// Directory of the focused terminal, shown as the subtitle.
    var currentDirectory: String? { get }
    func open(appID: String)
}

public struct PaletteSettingToggle: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var isOn: Bool
    public var keywords: [String]

    public init(id: String, title: String, isOn: Bool, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.isOn = isOn
        self.keywords = keywords
    }
}

public protocol PaletteSettingsSource: AnyObject {
    var toggles: [PaletteSettingToggle] { get }
    func setToggle(id: String, isOn: Bool)
}

public protocol PaletteRecentDirectorySource: AnyObject {
    /// Absolute paths, most recent first.
    var recentDirectories: [String] { get }
    func openDirectory(_ path: String)
}

/// The dynamic sources the palette can use. Every source is optional; a nil
/// source removes its provider and nested page.
public struct PaletteSources {
    public var workspaces: (any PaletteWorkspaceSource)?
    public var tabs: (any PaletteTabSource)?
    public var openIn: (any PaletteOpenInSource)?
    public var settings: (any PaletteSettingsSource)?
    public var recentDirectories: (any PaletteRecentDirectorySource)?
    /// Extra root providers (custom `cmux.json` actions, extensions).
    public var extraProviders: [any PaletteProvider]

    public init(
        workspaces: (any PaletteWorkspaceSource)? = nil,
        tabs: (any PaletteTabSource)? = nil,
        openIn: (any PaletteOpenInSource)? = nil,
        settings: (any PaletteSettingsSource)? = nil,
        recentDirectories: (any PaletteRecentDirectorySource)? = nil,
        extraProviders: [any PaletteProvider] = []
    ) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.openIn = openIn
        self.settings = settings
        self.recentDirectories = recentDirectories
        self.extraProviders = extraProviders
    }
}

// MARK: - Providers over the sources

/// Shortens a home-relative path to `~/…`.
func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

public final class WorkspacePaletteProvider: PaletteProvider {
    public let id = "workspaces"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteWorkspaceSource

    public init(source: any PaletteWorkspaceSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public static var section: PaletteSection {
        PaletteSection(id: "workspaces", title: PaletteStrings.sectionWorkspaces, order: 10)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.workspaces.map { workspace in
            let id = workspace.id
            return PaletteItem(
                id: "workspace:\(id)",
                title: workspace.title,
                subtitle: workspace.directory.map(abbreviatePath),
                accessory: workspace.isSelected ? PaletteStrings.current
                    : (workspace.unreadCount > 0 ? PaletteStrings.unreadCount(workspace.unreadCount) : nil),
                symbol: "rectangle.stack",
                section: Self.section,
                keywords: [PaletteStrings.workspaceKeyword],
                primary: PaletteCommand(id: "select", title: PaletteStrings.switchToWorkspace, symbol: "return", effect: .perform {
                    source.selectWorkspace(id: id)
                }),
                secondary: [
                    PaletteCommand(id: "rename", title: PaletteStrings.renameWorkspace, symbol: "pencil", effect: .textInput(PaletteTextInputSpec(
                        id: "rename-workspace:\(id)",
                        title: PaletteStrings.renameWorkspace,
                        placeholder: PaletteStrings.workspaceNamePlaceholder,
                        initialText: workspace.title,
                        submitTitle: PaletteStrings.renameTo,
                        submit: { source.renameWorkspace(id: id, to: $0) }
                    ))),
                    PaletteCommand(id: "close", title: PaletteStrings.closeWorkspace, symbol: "xmark.square", isDestructive: true, effect: .perform {
                        source.closeWorkspace(id: id)
                    }),
                    PaletteCommand(id: "copyID", title: PaletteStrings.copyID, symbol: "doc.on.doc", effect: .perform {
                        PaletteClipboard.copy(id)
                    }),
                ],
                frecencyKey: "workspace:\(id)",
                rankBias: workspace.isSelected ? -5 : 0
            )
        }
    }
}

public final class TabPaletteProvider: PaletteProvider {
    public let id = "tabs"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteTabSource

    public init(source: any PaletteTabSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public static var section: PaletteSection {
        PaletteSection(id: "tabs", title: PaletteStrings.sectionTabs, order: 20)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.tabs.map { tab in
            let id = tab.id
            let symbol: String = switch tab.kind {
            case .terminal: "terminal"
            case .browser: "globe"
            case .other(let symbol): symbol
            }
            return PaletteItem(
                id: "tab:\(id)",
                title: tab.title,
                subtitle: tab.workspaceTitle,
                accessory: tab.isSelected ? PaletteStrings.current : nil,
                symbol: symbol,
                section: Self.section,
                keywords: [PaletteStrings.tabKeyword],
                primary: PaletteCommand(id: "select", title: PaletteStrings.switchToTab, symbol: "return", effect: .perform {
                    source.selectTab(id: id)
                }),
                secondary: [
                    PaletteCommand(id: "rename", title: PaletteStrings.renameTab, symbol: "pencil", effect: .textInput(PaletteTextInputSpec(
                        id: "rename-tab:\(id)",
                        title: PaletteStrings.renameTab,
                        placeholder: PaletteStrings.tabNamePlaceholder,
                        initialText: tab.title,
                        submitTitle: PaletteStrings.renameTo,
                        submit: { source.renameTab(id: id, to: $0) }
                    ))),
                    PaletteCommand(id: "close", title: PaletteStrings.closeTab, symbol: "xmark", isDestructive: true, effect: .perform {
                        source.closeTab(id: id)
                    }),
                ],
                frecencyKey: "tab:\(id)"
            )
        }
    }
}

public final class OpenInPaletteProvider: PaletteProvider {
    public let id = "openIn"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteOpenInSource

    public init(source: any PaletteOpenInSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public static var section: PaletteSection {
        PaletteSection(id: "openIn", title: PaletteStrings.sectionOpenIn, order: 30)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        let directory = source.currentDirectory.map(abbreviatePath)
        return source.apps.map { app in
            let id = app.id
            return PaletteItem(
                id: "openIn:\(id)",
                title: PaletteStrings.openIn(app.name),
                subtitle: directory,
                symbol: app.symbol,
                section: Self.section,
                keywords: [app.name, "open in", "reveal"],
                primary: PaletteCommand(id: "open", title: PaletteStrings.open, symbol: "return", effect: .perform {
                    source.open(appID: id)
                }),
                frecencyKey: "openIn:\(id)"
            )
        }
    }
}

public final class SettingsPaletteProvider: PaletteProvider {
    public let id = "settings"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteSettingsSource

    public init(source: any PaletteSettingsSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public static var section: PaletteSection {
        PaletteSection(id: "settings", title: PaletteStrings.sectionSettings, order: 40)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.toggles.map { toggle in
            let id = toggle.id
            let next = !toggle.isOn
            return PaletteItem(
                id: "setting:\(id)",
                title: toggle.title,
                accessory: toggle.isOn ? PaletteStrings.on : PaletteStrings.off,
                symbol: toggle.isOn ? "checkmark.circle.fill" : "circle",
                section: Self.section,
                keywords: toggle.keywords + ["setting", "toggle", next ? "enable" : "disable"],
                primary: PaletteCommand(
                    id: "toggle",
                    title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff,
                    symbol: "switch.2",
                    effect: .performKeepingOpen { source.setToggle(id: id, isOn: next) }
                ),
                frecencyKey: "setting:\(id)"
            )
        }
    }
}

public final class RecentDirectoriesPaletteProvider: PaletteProvider {
    public let id = "recentDirectories"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteRecentDirectorySource

    public init(source: any PaletteRecentDirectorySource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    public static var section: PaletteSection {
        PaletteSection(id: "recentDirectories", title: PaletteStrings.sectionRecentDirectories, order: 50)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.recentDirectories.enumerated().map { position, path in
            PaletteItem(
                id: "directory:\(path)",
                title: (path as NSString).lastPathComponent,
                subtitle: abbreviatePath(path),
                symbol: "folder",
                section: Self.section,
                keywords: ["directory", "folder", "project"],
                primary: PaletteCommand(id: "open", title: PaletteStrings.openInNewWorkspace, symbol: "return", effect: .perform {
                    source.openDirectory(path)
                }),
                secondary: [
                    PaletteCommand(id: "copyPath", title: PaletteStrings.copyPath, symbol: "doc.on.doc", effect: .perform {
                        PaletteClipboard.copy(path)
                    }),
                ],
                frecencyKey: "directory:\(path)",
                rankBias: -min(position, 10)
            )
        }
    }
}
