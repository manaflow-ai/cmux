public import CmuxAgentCursor
public import QuartzCore

/// One window's agent cursor stack on the window-level cursor layer
/// (`WindowOverlayHost.agentCursorLayer`: y-down, window content-view
/// coordinates, above the sidebar and Chromium pages, below modals). The
/// stack and the layer are made on the first input this window draws; lease
/// and visibility changes never make them. The slot holds the layer it is
/// given, never the layer's superlayer (the layer moves between carriers).
public final class AgentCursorWindowSlot: AgentCursorRendering {
    private let resolver: AgentCursorTargetResolving
    private let color: AgentCursorLayerHost.Coloring
    private let hostLayer: () -> CALayer
    public private(set) var stack: AgentCursorStack?
    /// A target no cursor in this window follows any more.
    public var onUntrack: ((String) -> Void)?
    /// This window's entry point for published input (the provider-link
    /// input bridge and debug tools). It exists before the stack does; the
    /// first input this window draws makes the stack.
    public private(set) lazy var publisher = AgentCursorPublisher(renderer: self)

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
        publisher.publish(event)
    }

    /// `AgentCursorRendering` (called by `publisher` after its seq check).
    public func render(_ event: AutomationInputEvent) {
        if stack == nil {
            guard resolver.placement(forTarget: event.targetID) != .elsewhere else { return }
            let made = AgentCursorStack(hostLayer: hostLayer(), resolver: resolver, color: color)
            made.model.onUntrack = { [weak self] target in self?.onUntrack?(target) }
            stack = made
        }
        stack?.model.render(event)
    }

    public func leaseDidChange(session: String, state: AgentCursorLeaseState?) {
        stack?.model.leaseDidChange(session: session, state: state)
        if state == nil { publisher.endSession(session) }
    }

    public func placementsDidChange(target: String) {
        stack?.model.placementsDidChange(target: target)
    }

    public func endSession(_ session: String) {
        publisher.endSession(session)
    }
}
