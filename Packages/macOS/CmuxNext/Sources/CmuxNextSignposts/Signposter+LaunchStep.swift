import os

// The steps of the launch's start paths that other modules mark (the daemon connection, the first agent pane, the
// Ghostty runtime): one log-system point event per step, every time it happens, in the `launch` category. Like
// Chrome's startup trace events (components/startup_metric_utils/browser/startup_metric_utils.cc), the steps are
// events of the always-on `launch` category; the `launch.*` slices of the catalog are built from them
// (``SignpostName/launchDaemonReady``, task 034). A step is not a catalog name, so the trace ring takes none.
extension Signposter {
    /// The start path a launch step belongs to: the event's name, `launch.<source>`.
    public enum LaunchStepSource: Sendable, CaseIterable {
        /// The daemon start path (`DaemonLaunchTimings`): login environment, `server ensure`, connect, handshake.
        case daemon
        /// The first agent pane's load (`AgentPaneLaunchTimings`): view made, page loaded, handshake.
        case agentPane
        /// The libghostty runtime's one-time start (`TerminalTimings`): `ghostty_init`, config load, `ghostty_app_new`.
        case ghosttyRuntime

        /// The event's signpost name.
        public var name: StaticString {
            switch self {
            case .daemon: "launch.daemon"
            case .agentPane: "launch.agent_pane"
            case .ghosttyRuntime: "launch.ghostty_runtime"
            }
        }
    }

    /// Records one step of a launch start path as a point event named `source.name` whose public message is `step`
    /// (a fixed step name such as `daemon.handshake_end`, never user content).
    ///
    /// - Parameters:
    ///   - source: The start path the step belongs to.
    ///   - step: The step's fixed name.
    public func launchStep(_ source: LaunchStepSource, _ step: String) {
        assert(category == .launch, "launch steps are \(SignpostCategory.launch) signposts, not \(category)")
        signposter.emitEvent(source.name, "\(step, privacy: .public)")
    }
}
