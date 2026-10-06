import os

/// Marks of the first agent pane's load (view made, page loaded, page asked
/// for the handshake, handshake answered) for the App's `debug.timings` and
/// Instruments (signpost events, category "stalls"). The App installs the
/// receiver at launch; it keeps the first time of each name.
public enum AgentPaneLaunchTimings {
    private static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")
    private static var receiver: ((String) -> Void)?

    public static func install(_ receiver: @escaping (String) -> Void) {
        self.receiver = receiver
    }

    static func mark(_ name: String) {
        signposter.emitEvent("agent_pane", "\(name, privacy: .public)")
        receiver?(name)
    }
}
