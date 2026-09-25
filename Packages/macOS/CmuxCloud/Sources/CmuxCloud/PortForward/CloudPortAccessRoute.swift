/// Immutable transport choice shared by the browser provider and access model.
/// HTTPS keeps its certificate host; HTTP uses the authenticated userspace hub.
public enum CloudPortAccessRoute: Equatable, Sendable {
    case browserProxy
    case loopback
    case privateNetwork
}
