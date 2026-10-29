import AppKit
import CmuxNextBrowserImport
import LocalAuthentication
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Device owner authentication (Touch ID, Apple Watch or the login password) right before a
/// secret leaves the store (passwords.md 1.4: one success covers one row for one action).
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async -> Bool
}

/// LocalAuthentication `deviceOwnerAuthentication`; false when the Mac cannot evaluate it.
@MainActor
final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        // No synchronous canEvaluatePolicy on main: evaluatePolicy fails at once when the Mac cannot evaluate it.
        // A reply that never comes (the context dropped it) is a failed authentication.
        return (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            // The reply runs on a LocalAuthentication queue, never the main actor.
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable success, _ in
                continuation.resume(returning: success)
            }
        }) ?? false
    }
}

/// The native layer the page never reaches: the reveal sheet, the pasteboard and the export
/// file picker. Each gets the secret only after the person approved and authenticated.
@MainActor
protocol PasswordSecretSurface: AnyObject {
    /// Shows the password in a native sheet over `anchor`; returns when the sheet closes.
    func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async
    /// Copies the password to the pasteboard (concealed, transient, cleared after a while).
    func copy(_ secret: SecretBytes)
    /// Asks where to write the export; nil when the person cancelled.
    func exportDestination(profileName: String, anchor: NSView?) async -> URL?
}

//END
