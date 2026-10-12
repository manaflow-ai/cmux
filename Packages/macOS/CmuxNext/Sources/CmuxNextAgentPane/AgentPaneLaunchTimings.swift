import Foundation
import os

/// Marks of the first agent pane's load (view made, page loaded, page asked
/// for the handshake, handshake answered) for the App's `debug.timings` and
/// Instruments (signpost events, category "stalls"). The App installs the
/// receiver at launch; it keeps the first time of each name.
public final class AgentPaneLaunchTimings {
    public static let shared = AgentPaneLaunchTimings()
    private let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")
    private var receiver: ((String) -> Void)?
    private var early: [String] = [] // diag (to drop): marks before the receiver, with their time

    public func install(_ receiver: @escaping (String) -> Void) {
        self.receiver = receiver
        for name in early { receiver(name) }
        early.removeAll()
    }

    func mark(_ name: String) {
        signposter.emitEvent("agent_pane", "\(name, privacy: .public)")
        guard let receiver else {
            early.append(name.contains("@") ? name : "\(name)@\(Date().timeIntervalSince1970 * 1000)")
            return
        }
        receiver(name)
    }
}
