public import CmuxAgentCursor
public import QuartzCore

/// One window's agent cursor stack on the window-level cursor layer
/// (`WindowOverlayHost.agentCursorLayer`: y-down, window content-view
/// coordinates, above the sidebar and Chromium pages, below modals). The
/// stack and the layer are made on the first input this window draws; lease
/// and visibility changes never make them. The slot holds the layer it is
/// given, never the layer's superlayer (the layer moves between carriers).
public final class AgentCursorWindowSlot {
    private let resolver: AgentCursorTargetResolving
    private let color: AgentCursorLayerHost.Coloring
    private let hostLayer: () -> CALayer
    public private(set) var stack: AgentCursorStack?
    /// A target no cursor in this window follows any more.
    public var onUntrack: ((String) -> Void)?

    public init(
        resolver: AgentCursorTargetResolving, color: @escaping AgentCursorLayerHost.Coloring = AgentCursorStack.sessionColor,
        hostLayer: @escaping () -> CALayer
    ) {
        self.resolver = resolver
        self.color = color
        self.hostLayer = hostLayer
    }

    /// One published input. Makes the stack only when this window would draw it.
    public func publish(_ event: AutomationInputEvent) {
        _ = event
    }

    public func leaseDidChange(session: String, state: AgentCursorLeaseState?) {
        _ = (session, state)
    }

    public func placementsDidChange(target: String) {
        _ = target
    }

    public func endSession(_ session: String) {
        _ = session
    }
}
