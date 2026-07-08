import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case mobileConnect = "cmux.mobileconnect"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case newNote = "cmux.newNote"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"
    case more = "cmux.more"
    case rightSidebarFiles = "cmux.rightSidebar.files"
    case rightSidebarFind = "cmux.rightSidebar.find"
    case rightSidebarVault = "cmux.rightSidebar.vault"
    case rightSidebarFeed = "cmux.rightSidebar.feed"
    case rightSidebarDock = "cmux.rightSidebar.dock"
    case filesPane = "cmux.filesPane"
    case findPane = "cmux.findPane"
    case vaultPane = "cmux.vaultPane"
    case diffViewer = "cmux.diffViewer"
    case revealCurrentDirectoryInFinder = "cmux.revealCurrentDirectoryInFinder"
    case customizeSurfaceTabBar = "cmux.customizeSurfaceTabBar"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
             "cmux.connectPhone", "connectPhone":
            self = .mobileConnect
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.newNote", "newNote", "note":
            self = .newNote
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        case "cmux.more", "more":
            self = .more
        case "cmux.rightSidebar.files", "rightSidebar.files", "sidebar.files", "files":
            self = .rightSidebarFiles
        case "cmux.rightSidebar.find", "rightSidebar.find", "sidebar.find", "find":
            self = .rightSidebarFind
        case "cmux.rightSidebar.vault", "cmux.rightSidebar.sessions", "rightSidebar.vault",
             "rightSidebar.sessions", "sidebar.vault", "sidebar.sessions", "vault", "sessions":
            self = .rightSidebarVault
        case "cmux.rightSidebar.feed", "rightSidebar.feed", "sidebar.feed", "feed":
            self = .rightSidebarFeed
        case "cmux.rightSidebar.dock", "rightSidebar.dock", "sidebar.dock", "dock":
            self = .rightSidebarDock
        case "cmux.filesPane", "filesPane", "openFilesPane":
            self = .filesPane
        case "cmux.findPane", "findPane", "openFindPane":
            self = .findPane
        case "cmux.vaultPane", "vaultPane", "sessionsPane", "openVaultPane":
            self = .vaultPane
        case "cmux.diffViewer", "diffViewer", "diff", "diffs":
            self = .diffViewer
        case "cmux.revealCurrentDirectoryInFinder", "revealCurrentDirectoryInFinder",
             "openCurrentDirectoryInFinder", "finder":
            self = .revealCurrentDirectoryInFinder
        case "cmux.customizeSurfaceTabBar", "customizeSurfaceTabBar", "customizeTabBar",
             "customize":
            self = .customizeSurfaceTabBar
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .cloudVM:
            return "cloud"
        case .mobileConnect:
            return "iphone"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .newNote:
            return "doc.text"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        case .more:
            return "ellipsis.vertical"
        case .rightSidebarFiles:
            return "folder"
        case .rightSidebarFind:
            return "magnifyingglass"
        case .rightSidebarVault:
            return "books.vertical"
        case .rightSidebarFeed:
            return "dot.radiowaves.left.and.right"
        case .rightSidebarDock:
            return "dock.rectangle"
        case .filesPane:
            return "folder"
        case .findPane:
            return "magnifyingglass"
        case .vaultPane:
            return "books.vertical"
        case .diffViewer:
            return "doc.text.magnifyingglass"
        case .revealCurrentDirectoryInFinder:
            return "folder"
        case .customizeSurfaceTabBar:
            return "slider.horizontal.3"
        }
    }

    /// Short label for the surface tab bar's ⋯ menu, where the icon carries
    /// most of the meaning. The command palette keeps the longer descriptive
    /// titles from `CmuxResolvedConfigAction.builtIn` — a bare "Files" next
    /// to "Show Sidebar Files" would be ambiguous there.
    var menuTitle: String {
        switch self {
        case .newWorkspace:
            return String(localized: "surfaceTabBar.menu.newWorkspace", defaultValue: "Workspace")
        case .cloudVM:
            return String(localized: "surfaceTabBar.menu.cloudVM", defaultValue: "Cloud VM")
        case .mobileConnect:
            return String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")
        case .newTerminal:
            return String(localized: "surfaceTabBar.menu.newTerminal", defaultValue: "Terminal")
        case .newBrowser:
            return String(localized: "surfaceTabBar.menu.newBrowser", defaultValue: "Browser")
        case .newNote:
            return String(localized: "surfaceTabBar.menu.newNote", defaultValue: "Note")
        case .splitRight:
            return String(localized: "surfaceTabBar.menu.splitRight", defaultValue: "Split Right")
        case .splitDown:
            return String(localized: "surfaceTabBar.menu.splitDown", defaultValue: "Split Down")
        case .more:
            return String(localized: "surfaceTabBar.menu.more", defaultValue: "More")
        case .rightSidebarFiles:
            return String(localized: "surfaceTabBar.menu.rightSidebarFiles", defaultValue: "Files")
        case .rightSidebarFind:
            return String(localized: "surfaceTabBar.menu.rightSidebarFind", defaultValue: "Find")
        case .rightSidebarVault:
            return String(localized: "surfaceTabBar.menu.rightSidebarVault", defaultValue: "Vault")
        case .rightSidebarFeed:
            return String(localized: "surfaceTabBar.menu.rightSidebarFeed", defaultValue: "Feed")
        case .rightSidebarDock:
            return String(localized: "surfaceTabBar.menu.rightSidebarDock", defaultValue: "Dock")
        case .filesPane:
            return String(localized: "surfaceTabBar.menu.filesPane", defaultValue: "Files")
        case .findPane:
            return String(localized: "surfaceTabBar.menu.findPane", defaultValue: "Find")
        case .vaultPane:
            return String(localized: "surfaceTabBar.menu.vaultPane", defaultValue: "Vault")
        case .diffViewer:
            return String(localized: "surfaceTabBar.menu.diffViewer", defaultValue: "Diff")
        case .revealCurrentDirectoryInFinder:
            return String(localized: "surfaceTabBar.menu.revealInFinder", defaultValue: "Reveal")
        case .customizeSurfaceTabBar:
            return String(localized: "surfaceTabBar.menu.customize", defaultValue: "Customize")
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .rightSidebarFeed:
            return RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults)
        case .rightSidebarDock:
            return RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        // `.newNote` is deliberately NOT gated on the Notes sidebar beta: the
        // flag hides the right-sidebar Notes tab, while attached-note creation
        // (tab-bar button, More menu, ⌘⌃N) ships for everyone. Covered by
        // testDefaultSurfaceTabBarMoreMenuIncludesNotesWhenSidebarBetaDisabled.
        case .newWorkspace, .cloudVM, .mobileConnect, .newTerminal, .newBrowser, .newNote,
             .splitRight, .splitDown, .more, .rightSidebarFiles, .rightSidebarFind, .rightSidebarVault,
             .filesPane, .findPane, .vaultPane, .diffViewer,
             .revealCurrentDirectoryInFinder, .customizeSurfaceTabBar:
            return true
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM, .mobileConnect, .newNote, .more, .rightSidebarFiles, .rightSidebarFind,
             .rightSidebarVault, .rightSidebarFeed, .rightSidebarDock, .filesPane,
             .findPane, .vaultPane, .diffViewer, .revealCurrentDirectoryInFinder,
             .customizeSurfaceTabBar:
            return nil
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        }
    }
}
