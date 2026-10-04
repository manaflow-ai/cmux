public import CmuxAgentCursor
public import QuartzCore

/// The agent cursor parts for one content area, wired once: the publisher
/// (the one entry point drivers call), the overlay model and the CALayer
/// host on the area's `OverlayPlane` layer. The resolver slot answers
/// `.elsewhere` until the visibility adapter is set, so the stack draws
/// nothing and does no work until both a producer and a resolver exist.
public final class AgentCursorStack {
    public let publisher: AgentCursorPublisher
    public let model: AgentCursorOverlayModel
    public let host: AgentCursorLayerHost
    public let resolver: AgentCursorResolverSlot

    public init(hostLayer: CALayer, color: @escaping AgentCursorLayerHost.Coloring = AgentCursorStack.sessionColor) {
        let resolver = AgentCursorResolverSlot()
        let host = AgentCursorLayerHost(hostLayer: hostLayer, color: color)
        let model = AgentCursorOverlayModel(resolver: resolver, host: host)
        self.resolver = resolver
        self.host = host
        self.model = model
        publisher = AgentCursorPublisher(renderer: model)
    }

    /// The session's cursor fill: its cmux-cua palette mid color
    /// (`AgentCursorPalette.forSession`), the color the cmux-cua renderer,
    /// the lease badge and the activity rows use for that session.
    nonisolated public static func sessionColor(_ session: String) -> CGColor {
        let mid = AgentCursorPalette.forSession(session).cursorMid
        guard mid.count == 4, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return CGColor(gray: 0.96, alpha: 1)
        }
        let components = mid.map { CGFloat($0) / 255 }
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0.96, alpha: 1)
    }
}

/// Holds the visibility resolver once it exists (a9's App adapter); answers
/// `.elsewhere` for every target until then.
public final class AgentCursorResolverSlot: AgentCursorTargetResolving {
    public var inner: AgentCursorTargetResolving?

    public init() {}

    public func placement(forTarget targetID: String) -> AgentCursorPlacement {
        inner?.placement(forTarget: targetID) ?? .elsewhere
    }
}
