/// Why a user-triggered legacy hidden-computer recovery found no recoverable Mac.
public enum MobileHiddenComputerRecoveryFailureReason: Equatable, Sendable {
    /// The physical Mac was discovered, but the hidden app instance was not live.
    ///
    /// The associated value is the exact app-instance tag recorded by the hidden marker.
    case instanceNotLive(instanceTag: String?)

    /// No discovered Mac matched the hidden marker's physical device identifier.
    case deviceNotFound

    /// The exact hidden app instance was discovered without a usable Iroh route.
    case noIrohRoute

    /// This phone has no Iroh discovery client, so recovery cannot search at all.
    case irohUnavailable

    /// A matching live candidate was discovered but the authenticated connect failed.
    case connectFailed
}
