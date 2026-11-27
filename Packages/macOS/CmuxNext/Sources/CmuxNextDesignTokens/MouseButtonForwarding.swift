/// A view that may send every mouse button somewhere else: the remote desktop view in control
/// mode sends them to its host. App-wide mouse handling (`MouseSideButtons`) leaves the buttons
/// to such a view while `forwardsMouseButtons` is true.
public protocol MouseButtonForwarding: AnyObject {
    var forwardsMouseButtons: Bool { get }
}
