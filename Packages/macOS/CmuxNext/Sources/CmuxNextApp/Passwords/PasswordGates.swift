import AppKit
import CmuxNextBrowserImport
import LocalAuthentication

/// Device owner authentication (Touch ID, Apple Watch or the login password) right before a
/// secret leaves the store (passwords.md 1.4: one success covers one row for one action).
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async -> Bool
}

/// LocalAuthentication `deviceOwnerAuthentication`; false when the Mac cannot evaluate it.
@MainActor
final class LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    private final class ContextBox: @unchecked Sendable {
        let context: LAContext
        init(_ context: LAContext) { self.context = context }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var finished = false

        nonisolated func install(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if finished { continuation.resume(returning: false) } else { self.continuation = continuation }
        }

        nonisolated func finish(_ answer: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: answer)
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        let contextBox = ContextBox(context)
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let reply = Reply()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                reply.install(continuation)
                // The reply runs on a LocalAuthentication queue, never the main actor.
                contextBox.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable success, _ in
                    reply.finish(success)
                }
            }
        }, onCancel: {
            contextBox.context.invalidate()
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
