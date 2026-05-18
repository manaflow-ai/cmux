import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"
    case rightSidebarToggle = "cmux.rightSidebar.toggle"
    case rightSidebarShow = "cmux.rightSidebar.show"
    case rightSidebarHide = "cmux.rightSidebar.hide"
    case rightSidebarFocus = "cmux.rightSidebar.focus"
    case rightSidebarFiles = "cmux.rightSidebar.files"
    case rightSidebarFind = "cmux.rightSidebar.find"
    case rightSidebarVault = "cmux.rightSidebar.vault"
    case rightSidebarSessions = "cmux.rightSidebar.sessions"
    case rightSidebarFeed = "cmux.rightSidebar.feed"
    case rightSidebarDock = "cmux.rightSidebar.dock"

    static let rightSidebarActions: [CmuxSurfaceTabBarBuiltInAction] = allCases.filter {
        $0.rightSidebarRemoteCommand != nil
    }

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
        case "cmux.rightSidebar.toggle", "rightSidebar.toggle":
            self = .rightSidebarToggle
        case "cmux.rightSidebar.show", "rightSidebar.show":
            self = .rightSidebarShow
        case "cmux.rightSidebar.hide", "rightSidebar.hide":
            self = .rightSidebarHide
        case "cmux.rightSidebar.focus", "rightSidebar.focus":
            self = .rightSidebarFocus
        case "cmux.rightSidebar.files", "rightSidebar.files":
            self = .rightSidebarFiles
        case "cmux.rightSidebar.find", "rightSidebar.find":
            self = .rightSidebarFind
        case "cmux.rightSidebar.vault", "rightSidebar.vault":
            self = .rightSidebarVault
        case "cmux.rightSidebar.sessions", "rightSidebar.sessions":
            self = .rightSidebarSessions
        case "cmux.rightSidebar.feed", "rightSidebar.feed":
            self = .rightSidebarFeed
        case "cmux.rightSidebar.dock", "rightSidebar.dock":
            self = .rightSidebarDock
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
        case .rightSidebarToggle, .rightSidebarShow, .rightSidebarHide:
            return "rectangle.righthalf.inset.filled"
        case .rightSidebarFocus:
            return "scope"
        case .rightSidebarFiles:
            return RightSidebarMode.files.symbolName
        case .rightSidebarFind:
            return RightSidebarMode.find.symbolName
        case .rightSidebarVault, .rightSidebarSessions:
            return RightSidebarMode.sessions.symbolName
        case .rightSidebarFeed:
            return RightSidebarMode.feed.symbolName
        case .rightSidebarDock:
            return RightSidebarMode.dock.symbolName
        }
    }

    var defaultTitle: String {
        switch self {
        case .newWorkspace:
            return String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
        case .cloudVM:
            return String(localized: "command.cloudVM.title", defaultValue: "Start Cloud VM")
        case .newTerminal:
            return String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab")
        case .newBrowser:
            return String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab")
        case .splitRight:
            return String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")
        case .splitDown:
            return String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")
        case .rightSidebarToggle:
            return String(localized: "shortcut.toggleRightSidebar.label", defaultValue: "Toggle Right Sidebar")
        case .rightSidebarShow:
            return String(localized: "command.rightSidebarShow.title", defaultValue: "Show Right Sidebar")
        case .rightSidebarHide:
            return String(localized: "command.rightSidebarHide.title", defaultValue: "Hide Right Sidebar")
        case .rightSidebarFocus:
            return String(localized: "command.rightSidebarFocus.title", defaultValue: "Focus Right Sidebar")
        case .rightSidebarFiles:
            return String(localized: "shortcut.switchRightSidebarToFiles.label", defaultValue: "Show Sidebar Files")
        case .rightSidebarFind:
            return String(localized: "shortcut.switchRightSidebarToFind.label", defaultValue: "Show Sidebar Find")
        case .rightSidebarVault:
            return String(localized: "shortcut.switchRightSidebarToVault.label", defaultValue: "Show Sidebar Vault")
        case .rightSidebarSessions:
            return String(localized: "command.rightSidebarSessions.title", defaultValue: "Show Sidebar Sessions")
        case .rightSidebarFeed:
            return String(localized: "shortcut.switchRightSidebarToFeed.label", defaultValue: "Show Sidebar Feed")
        case .rightSidebarDock:
            return String(localized: "shortcut.switchRightSidebarToDock.label", defaultValue: "Show Sidebar Dock")
        }
    }

    var defaultKeywords: [String] {
        switch self {
        case .newWorkspace:
            return ["create", "new", "workspace"]
        case .cloudVM:
            return ["cloud", "vm", "virtual", "machine", "remote"]
        case .newTerminal:
            return ["new", "terminal", "tab", "surface"]
        case .newBrowser:
            return ["new", "browser", "tab", "surface"]
        case .splitRight:
            return ["terminal", "split", "right"]
        case .splitDown:
            return ["terminal", "split", "down"]
        case .rightSidebarToggle:
            return ["right", "sidebar", "toggle"]
        case .rightSidebarShow:
            return ["right", "sidebar", "show"]
        case .rightSidebarHide:
            return ["right", "sidebar", "hide"]
        case .rightSidebarFocus:
            return ["right", "sidebar", "focus"]
        case .rightSidebarFiles:
            return ["right", "sidebar", "files"]
        case .rightSidebarFind:
            return ["right", "sidebar", "find", "search"]
        case .rightSidebarVault:
            return ["right", "sidebar", "vault", "sessions"]
        case .rightSidebarSessions:
            return ["right", "sidebar", "sessions", "vault"]
        case .rightSidebarFeed:
            return ["right", "sidebar", "feed"]
        case .rightSidebarDock:
            return ["right", "sidebar", "dock"]
        }
    }

    var rightSidebarRemoteCommand: RightSidebarRemoteCommand? {
        switch self {
        case .rightSidebarToggle:
            return .toggle
        case .rightSidebarShow:
            return .show
        case .rightSidebarHide:
            return .hide
        case .rightSidebarFocus:
            return .focus
        case .rightSidebarFiles:
            return .setMode(.files, focus: true)
        case .rightSidebarFind:
            return .setMode(.find, focus: true)
        case .rightSidebarVault, .rightSidebarSessions:
            return .setMode(.sessions, focus: true)
        case .rightSidebarFeed:
            return .setMode(.feed, focus: true)
        case .rightSidebarDock:
            return .setMode(.dock, focus: true)
        case .newWorkspace, .cloudVM, .newTerminal, .newBrowser, .splitRight, .splitDown:
            return nil
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM,
             .rightSidebarToggle, .rightSidebarShow, .rightSidebarHide, .rightSidebarFocus,
             .rightSidebarFiles, .rightSidebarFind, .rightSidebarVault, .rightSidebarSessions,
             .rightSidebarFeed, .rightSidebarDock:
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
