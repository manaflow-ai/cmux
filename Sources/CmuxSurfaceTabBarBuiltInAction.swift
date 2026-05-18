import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"

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
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM:
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
