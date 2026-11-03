public import CmuxNextActions
import CmuxNextHome

/// Home's Debug menu actions, one path for the menu and the palette (the App binds them once): Save Last
/// 10 Seconds (DEV and NIGHTLY: MessagesLab's flight recorder) and, in DEV builds, Agent Messages
/// Playground (``HomeAgentMessagePlayground``: the agent-message header variants live in the real Home
/// transcript, user 2026-11-02).
@MainActor
public struct HomeDebugActions {
    private let flightRecorderOff: String

    /// - Parameter flightRecorderOff: The refusal when the flight recorder is off or no Home conversation is open.
    public init(flightRecorderOff: String) {
        self.flightRecorderOff = flightRecorderOff
    }

    /// Binds `home.saveFlightRecording` and, in DEV builds, `home.agentMessagePlayground` (its `style`,
    /// `expanded`, `team`, `open`, `peer` and `dark` arguments switch the playground; none opens it as it is).
    public func bind(into registry: ActionRegistry) {
        let off = flightRecorderOff
        // Both run on the input's turn and finish there (a dump written, a window shown): nothing to wait for.
        registry.bindEffect("home.saveFlightRecording", effect: { _ in
            HomeFlightRecording.saveLastSeconds() == nil ? .refused(off) : .done
        })
        #if DEBUG
        registry.bindEffect("home.agentMessagePlayground", effect: { invocation in
            HomeAgentMessagePlayground.show(style: invocation["style"]?.intValue, expanded: invocation["expanded"]?.boolValue,
                                            team: invocation["team"]?.boolValue, open: invocation["open"]?.intValue,
                                            peer: invocation["peer"]?.stringValue, dark: invocation["dark"]?.boolValue)
            return .done
        })
        #endif
    }
}
