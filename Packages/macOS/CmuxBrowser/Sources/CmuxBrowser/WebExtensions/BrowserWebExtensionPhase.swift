/// Represents the complete lifecycle of one browser profile's WebExtension runtime.
public enum BrowserWebExtensionPhase: Equatable, Sendable {
    /// The runtime exists but loading has not started.
    case idle

    /// Approved extensions are being discovered and registered.
    case loading

    /// Extension registration completed successfully.
    case ready

    /// Navigation may continue, but one or more extension capabilities are unavailable.
    case degraded(BrowserWebExtensionFailure)

    /// The runtime is terminal and will not accept more work.
    case shutDown
}
