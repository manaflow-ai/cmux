import CmuxNextSignposts

/// Marks of an agent pane's page (view painted, page loaded, handshake asked
/// and answered, a new tab's paint and context) for the App's `debug.timings`
/// and the trace: each mark is one ``SignpostName/webuiAgentPaneStep`` event,
/// every time it happens. The App installs the receiver at launch; it keeps
/// only the first time of each name as a launch mark.
public final class AgentPaneLaunchTimings {
    public static let shared = AgentPaneLaunchTimings()
    private let signposter: Signposter
    private var receiver: ((String) -> Void)?

    /// The marks of this module, in their fixed ring order: the `arg0` of a ``SignpostName/webuiAgentPaneStep``
    /// record is the mark's position + 1 (0 for a name outside the list). A new mark goes at the end, so older
    /// rings decode.
    enum Step: String, CaseIterable {
        case pageLoaded = "agent_pane.page_loaded"
        case painted = "agent_pane.painted"
        case handshakeStart = "agent_pane.handshake_start"
        case handshakeEnd = "agent_pane.handshake_end"
        case newTabPainted = "agent_pane.newtab_painted"
        case newTabContext = "agent_pane.newtab_context"

        /// The ring code of the mark `name`.
        static func traceCode(of name: String) -> UInt64 {
            allCases.firstIndex { $0.rawValue == name }.map { UInt64(clamping: $0) + 1 } ?? 0
        }
    }

    /// - Parameter signposter: Where the ``SignpostName/webuiAgentPaneStep`` event of each mark goes (a `webui`
    ///   signposter).
    init(signposter: Signposter = Signposter(category: .webui)) {
        self.signposter = signposter
    }

    public func install(_ receiver: @escaping (String) -> Void) {
        self.receiver = receiver
    }

    func mark(_ name: String) {
        signposter.event(.webuiAgentPaneStep, name, arg0: Step.traceCode(of: name))
        receiver?(name)
    }
}
