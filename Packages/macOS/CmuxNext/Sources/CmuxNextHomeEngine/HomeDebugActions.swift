public import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
public import Foundation

/// Home's Debug menu actions, one path for the menu and the palette (the App binds them once): Save Last
/// 10 Seconds (DEV and NIGHTLY: MessagesLab's flight recorder) and, in DEV builds, Agent Messages
/// Playground (``HomeAgentMessagePlayground``: the agent-message header variants live in the real Home
/// transcript, user 2026-11-02), and All Themes Playground (DEV and NIGHTLY, ``AllThemesPlaygroundWindow``:
/// every bundled theme as the App Theme, each element's contrast, user 2026-11-03).
@MainActor
public struct HomeDebugActions {
    private let flightRecorderOff: String
    private let themeFolders: [URL]

    /// - Parameters:
    ///   - flightRecorderOff: The refusal when the flight recorder is off or no Home conversation is open.
    ///   - themeFolders: The bundled theme folders the All Themes playground reads.
    public init(flightRecorderOff: String, themeFolders: [URL] = []) {
        self.flightRecorderOff = flightRecorderOff
        self.themeFolders = themeFolders
    }

    /// Binds `home.saveFlightRecording`, `debug.allThemesPlayground` and, in DEV builds, `home.agentMessagePlayground` (its `style`,
    /// `expanded`, `team`, `open`, `peer` and `dark` arguments switch the playground; none opens it as it is) and
    /// `home.chiefTeleportPlayground` (its `state` picks the menu shown beside the chips).
    public func bind(into registry: ActionRegistry) {
        let off = flightRecorderOff
        // Both run on the input's turn and finish there (a dump written, a window shown): nothing to wait for.
        registry.bindEffect("home.saveFlightRecording", effect: { _ in
            HomeFlightRecording.saveLastSeconds() == nil ? .refused(off) : .done
        })
        registry.bindEffect("debug.allThemesPlayground", effect: { [playground = AllThemesPlaygroundWindow(folders: themeFolders)] _ in
            playground.show()
            return .done
        })
        #if DEBUG
        registry.bindEffect("home.agentMessagePlayground", effect: { invocation in
            HomeAgentMessagePlayground.show(style: invocation["style"]?.intValue, expanded: invocation["expanded"]?.boolValue,
                                            team: invocation["team"]?.boolValue, open: invocation["open"]?.intValue,
                                            peer: invocation["peer"]?.stringValue, dark: invocation["dark"]?.boolValue)
            return .done
        })
        registry.bindEffect("home.mcpConnectPlayground", effect: { invocation in
            McpConnectCardPlayground.show(style: invocation["style"]?.intValue, fixture: invocation["fixture"]?.intValue,
                                          phase: invocation["phase"]?.intValue)
            return .done
        })
        // Debug > Chief Teleport Playground: the location chip variants in every state, light and dark.
        registry.bindEffect("home.chiefTeleportPlayground", effect: { invocation in
            ChiefTeleportPlayground.show(state: invocation["state"]?.intValue)
            return .done
        })
        #endif
    }
}
