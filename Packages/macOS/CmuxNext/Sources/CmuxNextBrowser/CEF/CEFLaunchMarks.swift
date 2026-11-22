public import Foundation

/// The browser pane's launch marks: `browser_pane.first_paint`, the first page a person sees in a Chromium tab
/// presented its first frame (``CEFTab/documentPainted``), and `browser_pane.input_ready`, the first such page took
/// keys (``CEFTab/onReadyForKeys``). Once per launch each (the App keeps a mark's first time); a tab an agent drives,
/// one not in front and a blank New Tab page count for neither. scripts/ci/launch_tti_check.py reads them beside the
/// terminal's `first_terminal_frame` and `terminal_echo` and the chat's `agent_pane.painted` and
/// `agent_pane.input_echoed`.
///
/// Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our motherfucking agent
/// pane."
///
/// The App installs the receiver at launch (``DebugTimings``); a mark made before that waits with its time.
public enum CEFLaunchMarks {
    public static let firstPaint = "browser_pane.first_paint"
    public static let inputReady = "browser_pane.input_ready"

    private static var sink: ((String, Date) -> Void)?
    private static var early: [(String, Date)] = []
    private static var made: Set<String> = []

    /// Takes every mark from now on, and the ones made before.
    public static func install(_ receiver: @escaping (String, Date) -> Void) {
        sink = receiver
        let waiting = early
        early.removeAll()
        for (name, date) in waiting { receiver(name, date) }
    }

    /// Whether a tab's page counts: one a person opened (not an agent's), in front, showing a real page.
    static func counts(agentDriven: Bool, inFront: Bool, blank: Bool) -> Bool {
        !agentDriven && inFront && !blank
    }

    /// Marks `name` the first time this launch; later calls do nothing.
    static func mark(_ name: String, at date: Date = Date()) {
        guard made.insert(name).inserted else { return }
        if let sink { sink(name, date) } else { early.append((name, date)) }
    }

    /// Tests only: a fresh launch.
    static func resetForTests() {
        (sink, early, made) = (nil, [], [])
    }
}

extension CEFTab {
    /// Whether this tab's paint and key readiness are the launch's browser marks (``CEFLaunchMarks/counts``).
    var countsForLaunchMarks: Bool {
        CEFLaunchMarks.counts(agentDriven: isAgentDriven, inFront: host.visibleTab === self, blank: blankIsDocument)
    }
}
