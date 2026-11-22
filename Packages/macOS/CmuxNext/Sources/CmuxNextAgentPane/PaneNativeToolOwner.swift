import CmuxNextCompat
public import Observation

/// Separates observable page ownership from AppKit's non-observable view hierarchy.
@MainActor @Observable
public final class PaneNativeToolOwner {
    public weak var model: AgentPaneModel?
    public init(model: AgentPaneModel? = nil) { self.model = model }
}
