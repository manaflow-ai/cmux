import AppKit
import CmuxNextBrowserImport
import CmuxNextCompat
import LocalAuthentication

/// Device owner authentication (Touch ID, Apple Watch or the login password) right before a
/// secret leaves the store (passwords.md 1.4: one success covers one row for one action).
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async -> Bool
}

@MainActor
private final class AuthContextBox {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}

// app-type-allow: private LAContext callback state must stay beside the app-owned authenticator.
private final class AuthReply: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Bool, Never>?, finished: Bool)>((nil, false))

    nonisolated func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let resume = state.withLock { state -> Bool in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        if resume { continuation.resume(returning: false) }
    }

    nonisolated func finish(_ answer: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: answer)
    }
}

/// LocalAuthentication `deviceOwnerAuthentication`; false when the Mac cannot evaluate it.
@MainActor
final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        let contextBox = AuthContextBox(context)
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let reply = AuthReply()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                reply.install(continuation)
                // The reply runs on a LocalAuthentication queue, never the main actor.
                contextBox.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable success, _ in
                    reply.finish(success)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                contextBox.context.invalidate()
            }
            reply.finish(false)
        })
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
