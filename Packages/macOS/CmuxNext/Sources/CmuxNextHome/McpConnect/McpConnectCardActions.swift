import Foundation

/// What the card's controls call. The host turns each into a ``McpConnectCardFlow`` step and sends
/// the step's effects to the daemon; the playground only steps the flow.
public struct McpConnectCardActions {
    public var choose: (McpConnectCard.Scope) -> Void
    public var connect: () -> Void
    public var cancel: () -> Void
    public var submitKey: (McpConnectKey) -> Void

    public init(choose: @escaping (McpConnectCard.Scope) -> Void, connect: @escaping () -> Void,
                cancel: @escaping () -> Void, submitKey: @escaping (McpConnectKey) -> Void) {
        self.choose = choose
        self.connect = connect
        self.cancel = cancel
        self.submitKey = submitKey
    }
}
