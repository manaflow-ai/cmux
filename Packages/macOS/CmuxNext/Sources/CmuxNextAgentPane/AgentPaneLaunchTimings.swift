import CmuxNextSignposts

/// Marks of the first agent pane's load (view made, page loaded, page asked
/// for the handshake, handshake answered) for the App's `debug.timings` and
/// Instruments (`launch.agent_pane` events, category "launch"). The App
/// installs the receiver at launch; it keeps the first time of each name.
public final class AgentPaneLaunchTimings {
    public static let shared = AgentPaneLaunchTimings()
    private let signposter: Signposter
    private var receiver: ((String) -> Void)?

    /// - Parameter signposter: Where each mark's `launch.agent_pane` event goes (a `launch` signposter).
    init(signposter: Signposter = .launch) {
        self.signposter = signposter
    }

    public func install(_ receiver: @escaping (String) -> Void) {
        self.receiver = receiver
    }

    func mark(_ name: String) {
        signposter.launchStep(.agentPane, name)
        receiver?(name)
    }
}
