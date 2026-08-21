import Foundation

/// Device-local persistence for the most recently approved local pairing.
///
/// The concrete iOS app stores this value in Keychain. Package previews use
/// the no-op default so no view owns credential-storage policy.
public protocol MobileLocalPairingCredentialStoring: Sendable {
    /// Loads the most recently connected local pairing URL.
    func loadAttachURL() async -> String?
    /// Replaces the stored local pairing after a successful connection.
    func saveAttachURL(_ attachURL: String) async
    /// Removes the local pairing during explicit sign-out.
    func clearAttachURL() async
}

/// A credential store that deliberately persists nothing.
public struct NoopMobileLocalPairingCredentialStore:
    MobileLocalPairingCredentialStoring {
    /// Creates a no-op credential store.
    public init() {}

    public func loadAttachURL() async -> String? { nil }
    public func saveAttachURL(_ attachURL: String) async {}
    public func clearAttachURL() async {}
}
