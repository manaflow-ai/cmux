/// The Labs keys every agent page follows (`labs.previewFeatures`, `labs.agentUiSurfaces`), as one value so
/// the app follows them with one observation.
public struct AgentPaneLabs: Equatable, Sendable {
    public var previewFeatures: Bool
    /// `labs.agentUiSurfaces`: interactive cards from agents (plans/cmux-next/agent-ui-surfaces-DESIGN.md), off by default.
    public var agentUiSurfaces: Bool

    public init(previewFeatures: Bool = false, agentUiSurfaces: Bool = false) {
        self.previewFeatures = previewFeatures
        self.agentUiSurfaces = agentUiSurfaces
    }

    /// Gives `view` both flags; the view pushes only a change.
    @MainActor
    public func push(to view: AgentPaneView) {
        view.previewFeatures = previewFeatures
        view.agentUiSurfaces = agentUiSurfaces
    }
}
