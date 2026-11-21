import Observation
public import CmuxNextDesign
public import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// The cmux NEXT own-window UI pointer inspector. Leo asked for it
    /// (ask-5077a4ec48), so it ships on; Debug Settings can still turn it off.
    public static let pointerInspector = Tunable<Bool>.toggle(
        "agent.pointerInspector", PageTunables.section, "UI pointer inspector",
        help: "Point at app-owned web pages (HTML/React, such as the agent chat) to inspect their components and attach the result to an agent composer. Native views are not inspectable.",
        default: true, code: "AgentPaneTunables.pointerInspector")
}

extension AgentPaneTunables {
    /// Calls `off` each time ``pointerInspector`` is turned off, for as long as the app runs. Arm it
    /// once the tunables are active (Debug Settings activates them after the app's services are
    /// built): a read of an inactive store registers no Observation dependency, so a watch armed
    /// earlier never fires (#36058).
    @MainActor public static func whenPointerInspectorTurnsOff(_ off: @escaping @MainActor () -> Void) {
        withObservationTracking { _ = pointerInspector.value } onChange: {
            Task { @MainActor in
                if !pointerInspector.value { off() }
                whenPointerInspectorTurnsOff(off)
            }
        }
    }
}
