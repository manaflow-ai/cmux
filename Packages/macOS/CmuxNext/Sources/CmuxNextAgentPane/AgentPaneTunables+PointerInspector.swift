public import CmuxNextDesign
public import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// The cmux NEXT own-window UI pointer inspector. It is a Debug/Labs
    /// prototype and stays off until the native and page paths are dogfooded.
    public static let pointerInspector = Tunable<Bool>.toggle(
        "agent.pointerInspector", PageTunables.section, "UI pointer inspector",
        help: "Point at cmux NEXT UI to inspect native views or app-owned webview components and attach the result to an agent composer.",
        default: false, code: "AgentPaneTunables.pointerInspector")
}
