import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newAgentChat = "cmux.newAgentChat"
    case cloudVM = "cmux.cloudvm"
    case newCloudWorkspace = "cmux.newCloudWorkspace"
    case mobileConnect = "cmux.mobileconnect"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
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
        case "cmux.newCloudWorkspace", "newCloudWorkspace", "cmux.newCloudMachine", "newCloudMachine":
            self = .newCloudWorkspace
        case "cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
             "cmux.connectPhone", "connectPhone":
            self = .mobileConnect
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
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
        case .newCloudWorkspace:
            return (String(localized: "command.newCloudWorkspace.title", defaultValue: "New Cloud Workspace"), ["new", "create", "cloud", "vm", "machine", "workspace", "remote"])
        case .mobileConnect:
            return (
                String(localized: "command.mobileConnect.title", defaultValue: "Open Tailscale Pairing"),
                ["tailscale", "iphone", "ipad", "mobile", "phone", "pair", "connect", "qr"]
            )
        case .newTerminal:
            return (String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab"), ["new", "terminal", "tab", "surface"])
        case .newBrowser:
            return (String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab"), ["new", "browser", "tab", "surface"])
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
        case .newCloudWorkspace:
            return "cloud.fill"
        case .mobileConnect:
            return "iphone"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
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
        case .newWorkspace, .newAgentChat, .cloudVM, .newCloudWorkspace, .mobileConnect, .newSimulator:
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

extension CmuxSurfaceTabBarBuiltInAction {
    /// The user-editable shortcut that triggers the same behavior as this
    /// built-in action. Menus that list built-in actions read the live
    /// `KeyboardShortcutSettings` value through this mapping, so a rebind or
    /// an unbind in Settings or `cmux.json` shows up the next time the menu
    /// opens. Actions with no cmux-owned shortcut return nil.
    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .newWorkspace: return .newTab
        case .newCloudWorkspace: return .newCloudWorkspace
        case .newTerminal: return .newSurface
        case .newBrowser: return .openBrowser
        case .splitRight: return .splitRight
        case .splitDown: return .splitDown
        case .newAgentChat, .cloudVM, .mobileConnect, .newSimulator: return nil
        }
    }

    /// Actions that launch a `cmux vm …` process and return before the
    /// workspace exists in `tabs[]`, so callers that need the created
    /// workspace (workspace-group placement) must observe the tab list.
    var createsWorkspaceAsynchronously: Bool {
        switch self {
        case .cloudVM, .newCloudWorkspace: return true
        case .newWorkspace, .newAgentChat, .mobileConnect, .newTerminal, .newBrowser, .newSimulator, .splitRight, .splitDown: return false
        }
    }
}
