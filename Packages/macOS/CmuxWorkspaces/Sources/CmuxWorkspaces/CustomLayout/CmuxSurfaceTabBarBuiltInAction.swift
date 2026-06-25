public import Bonsplit
import Foundation

/// A cmux built-in tab-bar / action-button identity in the `cmux.json` wire schema.
///
/// Each case is a stable `cmux.*` config identifier (its ``rawValue`` and
/// ``configID``). ``init(configID:)`` accepts the full set of historical aliases
/// for each action (bare names, casing variants, the legacy `newCloudVM` /
/// `startCloudVM` spellings) so older configs keep resolving. ``defaultIcon``
/// gives the SF Symbol name used when a button does not override its icon, and
/// ``bonsplitAction`` maps the split/new-surface actions onto the corresponding
/// ``BonsplitConfiguration/SplitActionButton/Action`` (workspace/cloud-VM
/// actions return `nil` because they are handled outside Bonsplit). The
/// hand-rolled ``Codable`` conformance encodes/decodes a single trimmed string
/// through ``init(configID:)``, throwing `DecodingError.dataCorrupted` on an
/// unknown identifier.
public enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// Open a new workspace (`cmux.newWorkspace`).
    case newWorkspace = "cmux.newWorkspace"
    /// Start a cloud VM workspace (`cmux.cloudvm`).
    case cloudVM = "cmux.cloudvm"
    /// Open a new terminal surface (`cmux.newTerminal`).
    case newTerminal = "cmux.newTerminal"
    /// Open a new browser surface (`cmux.newBrowser`).
    case newBrowser = "cmux.newBrowser"
    /// Split the current surface to the right (`cmux.splitRight`).
    case splitRight = "cmux.splitRight"
    /// Split the current surface downward (`cmux.splitDown`).
    case splitDown = "cmux.splitDown"

    /// Resolve a built-in action from a config identifier, accepting every
    /// historical alias and casing variant. Returns `nil` for an unknown id.
    public init?(configID: String) {
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

    /// The canonical `cmux.*` config identifier for this action.
    public var configID: String {
        rawValue
    }

    /// The SF Symbol name shown when a button does not override its icon.
    public var defaultIcon: String {
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

    /// The Bonsplit split/new-surface action this maps to, or `nil` for actions
    /// (workspace, cloud VM) handled outside Bonsplit.
    public var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(configID)
    }
}
