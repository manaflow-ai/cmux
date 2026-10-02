public import CmuxNextDesign
public import Foundation

/// Which agent pane page new agent tabs load (`agentPane.prototype` in Debug
/// Settings, DEV and NIGHTLY only). Two prototypes of the same pane are
/// compared live (plans/cmux-next/AGENT-BRIEF.md, "Prototypes for every
/// lane"): the current pane (`webviews/src/agent-session/acpmux`) and the port
/// of codex-atlas-clone (`webviews/src/agent-session-port`). Both speak the
/// same host contract, so the Swift host serves either unchanged. Release and
/// RC builds keep the tunable's default, the current pane.
public nonisolated enum AgentPanePrototype: String, Sendable, CaseIterable, TunableChoice {
    /// The pane on feat-cmux-next (`Resources/agent-pane/index.html`).
    case current
    /// The codex-atlas-clone port (`Resources/agent-pane/port/index.html`).
    case port

    public var tunableTitle: String {
        switch self {
        case .current: "Current (agent-session)"
        case .port: "Port (codex-atlas-clone)"
        }
    }

    /// The bundled page of this prototype, nil when the bundle lacks it.
    public var bundledPage: URL? {
        switch self {
        case .current: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane")
        case .port: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane/port")
        }
    }

    /// The prototype new agent tabs load now.
    public static var selected: AgentPanePrototype { AgentPaneTunables.prototype.value }
}

/// The agent pane's Debug Settings tunables.
public nonisolated enum AgentPaneTunables {
    public static let section = TunableSection(id: "agentPane", title: "Agent Pane", symbol: "bubble.left.and.text.bubble.right", order: 12)

    public static let prototype = Tunable<AgentPanePrototype>.choice(
        "agentPane.prototype", section, "Prototype",
        help: "Which agent pane page new agent tabs load: the current pane or the codex-atlas-clone port. Open tabs keep their page.",
        default: .current, code: "AgentPaneTunables.prototype")

    public static var all: [TunableDescriptor] { [prototype.descriptor] }
}
