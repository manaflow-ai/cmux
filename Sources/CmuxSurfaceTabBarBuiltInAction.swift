import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newAgentChat = "cmux.newAgentChat"
    case cloudVM = "cmux.cloudvm"
    case mobileConnect = "cmux.mobileconnect"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case newFileBrowser = "cmux.newFileBrowser"
    case newGitGraph = "cmux.newGitGraph"
    case newHerd = "cmux.newHerd"
    case newSimulator = "cmux.newSimulator"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat":
            self = .newAgentChat
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
        case "cmux.newFileBrowser", "newFileBrowser", "fileBrowser", "files":
            self = .newFileBrowser
        case "cmux.newGitGraph", "newGitGraph", "gitGraph", "git-graph", "graph":
            self = .newGitGraph
        case "cmux.newHerd", "newHerd", "herd", "agents":
            self = .newHerd
        case "cmux.newSimulator", "newSimulator", "new-simulator", "simulator":
            self = .newSimulator
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var resolvedConfigMetadata: (title: String, keywords: [String]) {
        switch self {
        case .newWorkspace:
            return (String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"), ["create", "new", "workspace"])
        case .newAgentChat:
            return (String(localized: "command.newAgentChat.title", defaultValue: "New agent chat"), ["create", "new", "agent", "chat", "browser", "codex", "claude"])
        case .cloudVM:
            return (String(localized: "command.cloudVM.title", defaultValue: "Open Base"), ["base", "cloud", "vm", "virtual", "machine", "remote"])
        case .mobileConnect:
            return (
                String(localized: "command.mobileConnect.title", defaultValue: "Open Tailscale Pairing"),
                ["tailscale", "iphone", "ipad", "mobile", "phone", "pair", "connect", "qr"]
            )
        case .newTerminal:
            return (String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab"), ["new", "terminal", "tab", "surface"])
        case .newBrowser:
            return (String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab"), ["new", "browser", "tab", "surface"])
        case .newFileBrowser:
            return (String(localized: "command.newFileBrowserTab.title", defaultValue: "New File Browser Tab"), ["new", "file", "browser", "explorer", "tree", "tab", "surface"])
        case .newGitGraph:
            return (String(localized: "command.newGitGraphTab.title", defaultValue: "New Git Graph Tab"), ["new", "git", "graph", "history", "branch", "commit", "tab", "surface"])
        case .newHerd:
            return (String(localized: "command.newHerdTab.title", defaultValue: "New Herd Tab"), ["new", "herd", "agent", "agents", "orchestration", "tab", "surface"])
        case .newSimulator:
            return (String(localized: "command.newSimulatorPane.title", defaultValue: "New Simulator Pane"), ["new", "simulator", "iphone", "ipad", "ios", "surface"])
        case .splitRight:
            return (String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right"), ["terminal", "split", "right"])
        case .splitDown:
            return (String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down"), ["terminal", "split", "down"])
        }
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .newAgentChat:
            return "message"
        case .cloudVM:
            return "cloud"
        case .mobileConnect:
            return "iphone"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .newFileBrowser:
            return "folder"
        case .newGitGraph:
            return "arrow.triangle.branch"
        case .newHerd:
            return "point.3.connected.trianglepath.dotted"
        case .newSimulator:
            return "iphone.gen3"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect, .newFileBrowser, .newGitGraph, .newHerd, .newSimulator:
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
