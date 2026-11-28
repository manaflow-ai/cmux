import os

/// Marks of the first agent pane's load (view made, page loaded, page asked
/// for the handshake, handshake answered) for the App's `debug.timings` and
/// Instruments (signpost events, category "stalls"). The App installs the
/// receiver at launch; it keeps the first time of each name.
public final class AgentPaneLaunchTimings {
    public static let shared = AgentPaneLaunchTimings()
    private let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")
    private var receiver: ((String) -> Void)?

    public func install(_ receiver: @escaping (String) -> Void) {
        self.receiver = receiver
    }

    func mark(_ name: String) {
        signposter.emitEvent("agent_pane", "\(name, privacy: .public)")
        receiver?(name)
    }
}
