import Foundation

/// Controls whether a Keychain request may present authentication UI.
public enum MobileRemoteSecretInteraction: Equatable, Sendable {
    /// Fail without UI, suitable for background reconnect and app launch.
    case nonInteractive
    /// Permit an OS authentication prompt with the supplied user-facing reason.
    case userInitiated(localizedReason: String)

    /// Validates a reason before it reaches LocalAuthentication.
    func validate() throws {
        guard case let .userInitiated(reason) = self else { return }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.utf8.count <= 512,
              !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw MobileRemoteSecretStoreError.invalidLocalizedReason
        }
    }
}
