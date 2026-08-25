public import CMUXMobileCore

/// The privacy-safe result of requesting a fresh broker discovery snapshot.
///
/// Failures carry only the bounded diagnostic category. The outcome never
/// retains an error description, endpoint identity, relay URL, account value,
/// or network address.
public enum CmxIrohLiveDiscoveryRefreshOutcome: Equatable, Sendable {
    /// A new verified broker snapshot was installed for first-pair discovery.
    case refreshed

    /// No new live snapshot was installed for the given categorical reason.
    case failed(DiagnosticFailureKind)
}
