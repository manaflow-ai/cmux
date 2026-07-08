public import Bonsplit
import Foundation

/// A built-in surface tab-bar action shipped with cmux (new workspace, Cloud VM,
/// Agent Chat, new terminal, new browser, split right, split down). Its raw value is the
/// canonical `cmux.*` config identifier used in `cmux.json`; legacy and
/// shorthand identifiers map onto a case through ``init(configID:)``. Decodes
/// from a single JSON string and maps to the matching `Bonsplit` split-action
/// where one exists.
public enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// Create a new workspace.
    case newWorkspace = "cmux.newWorkspace"
    /// Create a new Cloud VM workspace.
    case cloudVM = "cmux.cloudvm"
    /// Open the Agent Chat workspace.
    case newAgentChat = "cmux.newAgentChat"
    /// Connect a mobile device (iPhone) to this workspace.
    case mobileConnect = "cmux.mobileconnect"
    /// Open a new terminal surface.
    case newTerminal = "cmux.newTerminal"
    /// Open a new browser surface.
    case newBrowser = "cmux.newBrowser"
    /// Split the current surface to the right.
    case splitRight = "cmux.splitRight"
    /// Split the current surface downward.
    case splitDown = "cmux.splitDown"

    /// Resolves a config identifier (canonical `cmux.*`, legacy, or shorthand
    /// spelling) to its built-in action, or `nil` when no built-in matches.
    public init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat":
            self = .newAgentChat
        case "cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
             "cmux.connectPhone", "connectPhone":
            self = .mobileConnect
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

    /// The canonical `cmux.*` config identifier for this action.
    public var configID: String {
        rawValue
    }

    /// The default SF Symbol name shown for this action's tab-bar button.
    public var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .cloudVM:
            return "cloud"
        case .newAgentChat:
            return "message"
        case .mobileConnect:
            return "iphone"
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

    /// The `Bonsplit` split-action this maps to, or `nil` for actions
    /// (new workspace, Cloud VM) that `Bonsplit` does not drive.
    public var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM, .newAgentChat, .mobileConnect:
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
    /// Decodes from a single JSON string, trimming surrounding whitespace and
    /// resolving the value through ``init(configID:)``; throws
    /// `DecodingError.dataCorrupted` for an unknown identifier.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = Self(configID: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown built-in action '\(value)'"
                )
            )
        }
        self = action
    }

    /// Encodes as the canonical `cmux.*` config identifier in a single-value
    /// container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(configID)
    }
}
