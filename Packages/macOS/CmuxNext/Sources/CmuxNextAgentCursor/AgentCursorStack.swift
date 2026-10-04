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

    public init(hostLayer: CALayer, color: @escaping AgentCursorLayerHost.Coloring = AgentCursorStack.neutralColor) {
        let resolver = AgentCursorResolverSlot()
        let host = AgentCursorLayerHost(hostLayer: hostLayer, color: color)
        let model = AgentCursorOverlayModel(resolver: OneLayerPerEventStub(), host: host)
        self.resolver = resolver
        self.host = host
        self.model = model
        publisher = AgentCursorPublisher(renderer: model)
    }

    /// Until session colors arrive with the vendored package (cmux-cua
    /// v0.8.3, AgentCursorPalette), every cursor is a light arrow with a dark
    /// outline.
    nonisolated public static func neutralColor(_ session: String) -> CGColor {
        _ = session
        return CGColor(gray: 0.96, alpha: 1)
    }
}

/// Holds the visibility resolver once it exists (a9's App adapter); answers
/// `.elsewhere` for every target until then.
public final class AgentCursorResolverSlot: AgentCursorTargetResolving {
    public var inner: AgentCursorTargetResolving?

    public init() {}

    public func placement(forTarget targetID: String) -> AgentCursorPlacement {
        _ = (inner, targetID)
        return .visible(content: .zero, magnification: 1)
    }
}

/// Red-commit stand-in: claims every target is visible, so events draw.
final class OneLayerPerEventStub: AgentCursorTargetResolving {
    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        _ = targetID
        return .visible(content: CGRect(x: 0, y: 0, width: 1, height: 1), magnification: 1)
    }
}
