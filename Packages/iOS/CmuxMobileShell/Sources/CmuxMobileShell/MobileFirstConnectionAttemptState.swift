/// Mutually exclusive connection activity on the first-connection screen.
public struct MobileFirstConnectionAttemptState: Equatable, Sendable {
    /// Saved computer currently reconnecting, if any.
    public let connectingSavedComputerID: String?
    /// Account-private registry session currently handing off, if any.
    public let pendingHandoffID: String?

    /// Creates a snapshot of first-connection activity.
    /// - Parameters:
    ///   - connectingSavedComputerID: Saved computer currently reconnecting.
    ///   - pendingHandoffID: Registry session currently handing off.
    public init(
        connectingSavedComputerID: String?,
        pendingHandoffID: String?
    ) {
        self.connectingSavedComputerID = connectingSavedComputerID
        self.pendingHandoffID = pendingHandoffID
    }

    /// Whether another saved-computer reconnect or session handoff may start.
    public var canStartConnection: Bool {
        connectingSavedComputerID == nil && pendingHandoffID == nil
    }
}
