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
    private let label: AgentCursorLayerHost.Labeling
    private let hostLayer: () -> CALayer
    private let glassLayer: () -> CALayer?
    public private(set) var stack: AgentCursorStack?
    /// A target no cursor in this window follows any more.
    public var onUntrack: ((String) -> Void)?
    /// A cursor of this window came, went, showed or hid
    /// (``AgentCursorLayerHost/onTagsChange``): its clickable tags may have changed.
    public var onTagsChange: (() -> Void)?
    /// This window's entry point for published input (the provider-link
    /// input bridge and debug tools). It exists before the stack does; the
    /// first input this window draws makes the stack.
    public private(set) lazy var publisher = AgentCursorPublisher(renderer: self)
    /// What the next event of a session types, by its seq
    /// (``AgentCursorInputBridge/onTyping``), taken when it renders.
    private var pendingTyping: [String: (seq: UInt64, typing: AgentTyping)] = [:]

    /// Notes what `event` types; its `render` shows it.
    public func noteTyping(_ typing: AgentTyping, for event: AutomationInputEvent) {
        pendingTyping[event.sessionID] = (event.seq, typing)
    }

    public init(
        resolver: AgentCursorTargetResolving, color: @escaping AgentCursorLayerHost.Coloring = { _ in AgentCursorLayer.gray },
        label: @escaping AgentCursorLayerHost.Labeling = { AgentCursorSessionLabel(sessionID: $0).text },
        glassLayer: @escaping () -> CALayer? = { nil },
        hostLayer: @escaping () -> CALayer
    ) {
        self.glassLayer = glassLayer
        self.resolver = resolver
        self.color = color
        self.label = label
        self.hostLayer = hostLayer
    }

    /// One published input. Makes the stack only when this window would draw it.
    public func publish(_ event: AutomationInputEvent) {
        publisher.publish(event)
    }

    /// `AgentCursorRendering` (called by `publisher` after its seq check).
    public func render(_ event: AutomationInputEvent) {
        let pending = pendingTyping.removeValue(forKey: event.sessionID)
        if stack == nil {
            guard resolver.placement(forTarget: event.targetID) != .elsewhere else { return }
            let made = AgentCursorStack(hostLayer: hostLayer(), glassLayer: glassLayer(), resolver: resolver, color: color, label: label)
            made.model.onUntrack = { [weak self] target in self?.onUntrack?(target) }
            made.host.onTagsChange = { [weak self] in self?.onTagsChange?() }
            stack = made
        }
        stack?.model.render(event, typing: pending?.seq == event.seq ? pending?.typing : nil)
    }

    /// Removes every cursor of this window (the person turned the agent
    /// cursor off); the next input after it is back on draws again.
    public func removeAll() {
        guard let stack else { return }
        for session in stack.host.sessions {
            // As a lease end: the model forgets the cursor and its layer goes.
            stack.model.leaseDidChange(session: session, state: nil)
            publisher.endSession(session)
        }
        pendingTyping = [:]
    }

    public func leaseDidChange(session: String, state: AgentCursorLeaseState?) {
        stack?.model.leaseDidChange(session: session, state: state)
        if state == nil {
            publisher.endSession(session)
            pendingTyping[session] = nil
        }
    }

    public func placementsDidChange(target: String) {
        stack?.model.placementsDidChange(target: target)
    }

    public func endSession(_ session: String) {
        publisher.endSession(session)
    }
}
