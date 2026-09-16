/// Immutable transport choice shared by the browser provider and access model.
/// HTTPS keeps its certificate host; HTTP uses the authenticated userspace hub.
enum CloudPortAccessRoute: Equatable {
    case loopback
    case privateNetwork
}
