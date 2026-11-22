public import Foundation
import CmuxNextCompat

/// The browser pane's launch marks: `browser_pane.first_paint`, the first page a person sees in a Chromium tab
/// presented its first frame (``CEFTab/documentPainted``), and `browser_pane.input_ready`, the first such page took
/// keys (``CEFTab/onReadyForKeys``). Once per launch each; a tab an agent drives, one not in front and a blank New Tab
/// page count for neither. scripts/ci/launch_tti_check.py reads them beside the terminal's `first_terminal_frame` and
/// `terminal_echo` and the chat's `agent_pane.painted` and `agent_pane.input_echoed`.
///
/// Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our motherfucking agent
/// pane."
///
/// The App installs the receiver at launch (`DebugTimings.install`, beside ``AgentPaneLaunchTimings``); a mark made
/// before that waits with its time.
public nonisolated final class CEFLaunchMarks: Sendable {
    public static let shared = CEFLaunchMarks()
    public static let firstPaint = "browser_pane.first_paint"
    public static let inputReady = "browser_pane.input_ready"

    private struct State {
        var sink: (@Sendable (String, Date) -> Void)?
        var early: [(String, Date)] = []
        var made: Set<String> = []
    }

    private let state = Mutex(State())

    init() {}

    /// Takes every mark from now on, and the ones made before.
    public func install(_ receiver: @escaping @Sendable (String, Date) -> Void) {
        let early = state.withLock { state -> [(String, Date)] in
            state.sink = receiver
            defer { state.early.removeAll() }
            return state.early
        }
        for (name, date) in early { receiver(name, date) }
    }

    /// Whether a tab's page counts: one a person opened (not an agent's), in front, showing a real page.
    static func counts(agentDriven: Bool, inFront: Bool, blank: Bool) -> Bool {
        !agentDriven && inFront && !blank
    }

    /// Marks `name` the first time this launch; later calls do nothing.
    func mark(_ name: String, at date: Date = Date()) {
        let receiver = state.withLock { state -> (@Sendable (String, Date) -> Void)? in
            guard state.made.insert(name).inserted else { return nil }
            if state.sink == nil { state.early.append((name, date)) }
            return state.sink
        }
        receiver?(name, date)
    }
}

extension CEFTab {
    /// Whether this tab's paint and key readiness are the launch's browser marks (``CEFLaunchMarks/counts``).
    var countsForLaunchMarks: Bool {
        CEFLaunchMarks.counts(agentDriven: isAgentDriven, inFront: host.visibleTab === self, blank: blankIsDocument)
    }
}
