/// Immutable transport choice shared by the browser provider and access model.
/// HTTPS keeps its certificate host; HTTP uses the authenticated userspace hub.
public enum CloudPortAccessRoute: Hashable, Sendable {
    /// A local direct origin, retained for existing non-Cloud callers.
    case direct
    /// All browser origins are resolved and connected by the owning machine.
    case remoteBrowser
    case browserProxy
    case loopback
    case privateNetwork
}
