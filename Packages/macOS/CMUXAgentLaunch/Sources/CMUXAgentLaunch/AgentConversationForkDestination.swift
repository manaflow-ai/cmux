public import Foundation
import Bonsplit
import CmuxPanes

/// The destination an agent-conversation fork is sent to.
///
/// This is the ``AgentForkCoordinator`` `Destination` vocabulary: the value enum
/// the right-click context menu, the command palette, and the configured default
/// resolve a fork into. It is a faithful lift of the app-target enum the
/// `ContentView+ForkAgentConversation` extension declared; the byte-identical
/// `rawValue` cases are the `~/.config/cmux/cmux.json`
/// `forkConversationDefaultDestination` wire values and the persisted
/// `agentConversationForkDefaultDestination` `UserDefaults` value, both frozen.
///
/// It bridges three vocabularies that already live in lower packages, which is
/// why this type homes in `CMUXAgentLaunch` rather than a leaf: the Bonsplit
/// `TabContextAction` right-click actions (``init(tabContextAction:)`` /
/// ``tabContextAction``) and the `CmuxPanes` ``SplitDirection`` the split forks
/// consume (``splitDirection``). The localized display titles stay app-side in an
/// `extension AgentConversationForkDestination`, because `String(localized:)`
/// must resolve against the app bundle, not this package's bundle.
public enum AgentConversationForkDestination: String, CaseIterable, Identifiable, Sendable {
    /// Fork into a split to the right of the source pane.
    case right
    /// Fork into a split to the left of the source pane.
    case left
    /// Fork into a split above the source pane.
    case top
    /// Fork into a split below the source pane.
    case bottom
    /// Fork into a new sibling tab in the source pane.
    case newTab
    /// Fork into a brand-new workspace.
    case newWorkspace

    /// The stable identity (the `rawValue`).
    public var id: String { rawValue }

    /// Human-readable destination title for the Fork Conversation menu (#7259).
    public var settingsTitle: String {
        switch self {
        case .right:
            return String(localized: "forkConversation.destination.right", defaultValue: "Right Split")
        case .left:
            return String(localized: "forkConversation.destination.left", defaultValue: "Left Split")
        case .top:
            return String(localized: "forkConversation.destination.top", defaultValue: "Top Split")
        case .bottom:
            return String(localized: "forkConversation.destination.bottom", defaultValue: "Bottom Split")
        case .newTab:
            return String(localized: "forkConversation.destination.newTab", defaultValue: "New Tab")
        case .newWorkspace:
            return String(localized: "forkConversation.destination.newWorkspace", defaultValue: "New Workspace")
        }
    }

    /// The destination used when none is configured (right split).
    public static let defaultDestination: AgentConversationForkDestination = .right

    /// The `UserDefaults` / `cmux.json` key the configured fork default persists
    /// under. Frozen wire value.
    public static let defaultDestinationDefaultsKey = "agentConversationForkDefaultDestination"

    /// The configured default fork destination, read from `defaults` under
    /// ``defaultDestinationDefaultsKey`` and falling back to
    /// ``defaultDestination`` for a missing or unrecognized value. Faithful lift
    /// of the legacy `AgentConversationForkDefaultSettings.current(defaults:)`
    /// reader.
    public static func configuredDefault(
        defaults: UserDefaults = .standard
    ) -> AgentConversationForkDestination {
        guard let raw = defaults.string(forKey: defaultDestinationDefaultsKey),
              let destination = AgentConversationForkDestination(rawValue: raw) else {
            return defaultDestination
        }
        return destination
    }

    /// Maps a Bonsplit right-click `TabContextAction` to its fork destination,
    /// falling back to ``defaultDestination`` for any non-fork action.
    public init(tabContextAction: TabContextAction) {
        switch tabContextAction {
        case .forkConversationLeft:
            self = .left
        case .forkConversationTop:
            self = .top
        case .forkConversationBottom:
            self = .bottom
        case .forkConversationNewTab:
            self = .newTab
        case .forkConversationNewWorkspace:
            self = .newWorkspace
        case .forkConversationRight:
            self = .right
        default:
            self = .defaultDestination
        }
    }

    /// The Bonsplit right-click `TabContextAction` this destination corresponds
    /// to.
    public var tabContextAction: TabContextAction {
        switch self {
        case .right:
            return .forkConversationRight
        case .left:
            return .forkConversationLeft
        case .top:
            return .forkConversationTop
        case .bottom:
            return .forkConversationBottom
        case .newTab:
            return .forkConversationNewTab
        case .newWorkspace:
            return .forkConversationNewWorkspace
        }
    }

    /// The command-palette command identifier that triggers this fork
    /// destination.
    public var commandPaletteCommandId: String {
        switch self {
        case .right:
            return "palette.forkAgentConversationRight"
        case .left:
            return "palette.forkAgentConversationLeft"
        case .top:
            return "palette.forkAgentConversationTop"
        case .bottom:
            return "palette.forkAgentConversationBottom"
        case .newTab:
            return "palette.forkAgentConversationNewTab"
        case .newWorkspace:
            return "palette.forkAgentConversationNewWorkspace"
        }
    }

    /// The `CmuxPanes` split direction this destination forks into, or `nil` for
    /// the new-tab / new-workspace destinations that do not split.
    public var splitDirection: SplitDirection? {
        switch self {
        case .right:
            return .right
        case .left:
            return .left
        case .top:
            return .up
        case .bottom:
            return .down
        case .newTab, .newWorkspace:
            return nil
        }
    }
}
