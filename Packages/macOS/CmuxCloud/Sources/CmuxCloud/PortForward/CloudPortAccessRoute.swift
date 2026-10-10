/// Immutable transport choice shared by the browser provider and access model.
/// HTTPS keeps its certificate host; HTTP uses the authenticated userspace hub.
public enum CloudPortAccessRoute: Hashable, Sendable {
    /// A remote browser origin that is reachable directly from the Mac. The
    /// browser resource remains Cloud-owned; no machine-port transport is
    /// needed for a public page.
    case direct
    case browserProxy
    case loopback
    case privateNetwork
}
