public import CmuxNextDesign
public import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// The cmux NEXT own-window UI pointer inspector. Leo asked for it
    /// (ask-5077a4ec48), so it ships on; Debug Settings can still turn it off.
    public static let pointerInspector = Tunable<Bool>.toggle(
        "agent.pointerInspector", PageTunables.section, "UI pointer inspector",
        help: "Point at cmux NEXT UI to inspect native views or app-owned webview components and attach the result to an agent composer.",
        default: true, code: "AgentPaneTunables.pointerInspector")
}
