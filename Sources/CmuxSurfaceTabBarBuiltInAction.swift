import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
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
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        case "cmux.more":
            self = .more
        case "cmux.rightSidebar.files":
            self = .rightSidebarFiles
        case "cmux.rightSidebar.find":
            self = .rightSidebarFind
        case "cmux.rightSidebar.vault", "cmux.rightSidebar.sessions":
            self = .rightSidebarVault
        case "cmux.rightSidebar.feed":
            self = .rightSidebarFeed
        case "cmux.rightSidebar.dock":
            self = .rightSidebarDock
        case "cmux.filesPane":
            self = .filesPane
        case "cmux.findPane":
            self = .findPane
        case "cmux.vaultPane":
            self = .vaultPane
        case "cmux.diffViewer":
            self = .diffViewer
        case "cmux.revealCurrentDirectoryInFinder":
            self = .revealCurrentDirectoryInFinder
        case "cmux.customizeSurfaceTabBar":
            self = .customizeSurfaceTabBar
        default:
            return nil
        }
    }

    init?(builtinID: String) {
        if let action = Self(configID: builtinID) {
            self = action
            return
        }

        switch builtinID {
        case "more":
            self = .more
        case "rightSidebar.files", "sidebar.files", "files":
            self = .rightSidebarFiles
        case "rightSidebar.find", "sidebar.find", "find":
            self = .rightSidebarFind
        case "rightSidebar.vault", "rightSidebar.sessions", "sidebar.vault",
             "sidebar.sessions", "vault", "sessions":
            self = .rightSidebarVault
        case "rightSidebar.feed", "sidebar.feed", "feed":
            self = .rightSidebarFeed
        case "rightSidebar.dock", "sidebar.dock", "dock":
            self = .rightSidebarDock
        case "filesPane", "openFilesPane":
            self = .filesPane
        case "findPane", "openFindPane":
            self = .findPane
        case "vaultPane", "sessionsPane", "openVaultPane":
            self = .vaultPane
        case "diffViewer", "diff", "diffs":
            self = .diffViewer
        case "revealCurrentDirectoryInFinder", "openCurrentDirectoryInFinder", "finder":
            self = .revealCurrentDirectoryInFinder
        case "customizeSurfaceTabBar", "customizeTabBar", "customize":
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
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
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
            return "folder.badge.plus"
        case .findPane:
            return "doc.text.magnifyingglass"
        case .vaultPane:
            return "books.vertical.fill"
        case .diffViewer:
            return "plusminus"
        case .revealCurrentDirectoryInFinder:
            return "folder"
        case .customizeSurfaceTabBar:
            return "slider.horizontal.3"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM, .more, .rightSidebarFiles, .rightSidebarFind,
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
