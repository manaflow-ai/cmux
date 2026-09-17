import CmuxTerminal

/// Count-only view telemetry read on the actor that owns the native surfaces.
struct MemoryResourceViewCounts: Sendable {
    let visibleTerminals: Int
    let realizedRenderers: Int
    let presentedRenderers: Int
    let browserStates: [String: Int]

    @MainActor
    static func capture() -> Self {
        let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfacesUnordered()
        let browsers = AppDelegate.shared?.browserPanelsForInspectorFocusHandoff() ?? []
        return Self(
            visibleTerminals: surfaces.filter(\.isRendererEffectivelyVisible).count,
            realizedRenderers: surfaces.filter(\.isRendererRealized).count,
            presentedRenderers: surfaces.filter(\.isRendererPresented).count,
            browserStates: browsers.reduce(into: [:]) {
                $0[$1.webViewLifecycleState.rawValue, default: 0] += 1
            }
        )
    }

    func payload() -> [String: Any] {
        [
            "visible_terminal_count": visibleTerminals,
            "realized_renderer_count": realizedRenderers,
            "presented_renderer_count": presentedRenderers,
            "browser_panel_count": browserStates.values.reduce(0, +),
            "browser_lifecycle_counts": browserStates
        ]
    }
}
