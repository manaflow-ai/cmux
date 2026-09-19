import AppKit
import CmuxSettings
import Foundation

/// MDM master switches for the capabilities that reach off this Mac.
///
/// Each type is the single authoritative answer to "may cmux do this at all",
/// so every entry point (UI, command palette, menus, CLI, socket, session
/// restore, automation) composes the same check instead of repeating the
/// resolver lookup. All of them default to *allowed*: an unmanaged Mac, and a
/// managed Mac whose profile does not force the key, behave exactly as before.
///
/// Decisions read only the forced-preference resolver. Tests inject a resolver
/// into the resource owner instead of replacing process-wide policy state.
enum ManagedRemoteConnectionsPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableRemoteConnections`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableRemoteConnections)
    }

    static var isEnabled: Bool { !isDisabled }

    /// The message shown wherever a refusal surfaces to the user.
    static var disabledMessage: String {
        String(
            localized: "managedPolicy.remoteConnections.disabled",
            defaultValue: "Remote connections are disabled by your organization."
        )
    }
}

/// MDM master switch for cmux-mediated file transfer.
enum ManagedFileTransferPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableFileTransfer`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableFileTransfer)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        )
    }

    /// The failure handed to upload callers. An `NSError` rather than a new
    /// `RemoteDropUploadError` case, so the shared package enum keeps its
    /// exhaustive switches intact.
    static func refusalError() -> NSError {
        NSError(
            domain: refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: disabledMessage]
        )
    }

    static let refusalErrorDomain = "cmux.managedPolicy.fileTransfer"

    /// Whether `error` is this policy's refusal (as opposed to a transport
    /// failure), so a drop or paste handler can explain it instead of beeping.
    static func isRefusal(_ error: Error) -> Bool {
        (error as NSError).domain == refusalErrorDomain
    }

    /// Tells the user why the drop or paste did nothing. The failure handlers
    /// otherwise reduce every upload error to a beep, which would leave a
    /// managed refusal indistinguishable from a broken connection. Callable
    /// from any context: the alert is presented on the main actor.
    static func presentRefusal() {
        let message = disabledMessage
        let detail = String(
            localized: "managedPolicy.fileTransfer.refusalDetail",
            defaultValue: "cmux did not upload the file. Your organization's device policy disables file transfer through cmux."
        )
        let present: @MainActor () -> Void = {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.alertStyle = .informational
            alert.runModal()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(present)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(present) }
        }
    }
}

/// MDM master switch for cmux Cloud (`DisableCloud`), for the gates that
/// have no injectable resolver of their own: the action chokepoint, the
/// non-`vm.*` control-plane socket verbs, and the control-plane clients.
/// `VMClient`, the tunnel coordinator, and session restore keep their
/// injected resolvers.
enum ManagedCloudPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableCloud`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableCloud)
    }

    static var isEnabled: Bool { !isDisabled }

    /// The stable socket error code every Cloud refusal carries.
    static let socketErrorCode = "cloud_disabled"

    static var disabledMessage: String {
        String(
            localized: "cloud.managed.disabled",
            defaultValue: "Cloud Machines are disabled by your administrator."
        )
    }
}

/// MDM master switch for uploading local AI credentials (Claude/Codex OAuth
/// tokens, Anthropic/OpenAI API keys) to the cmux tenant. Independent of
/// `DisableCloud`, which already refuses the same families.
enum ManagedAICredentialUploadPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableAICredentialUpload`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableAICredentialUpload)
    }

    static var isEnabled: Bool { !isDisabled }

    static let socketErrorCode = "ai_credential_upload_disabled"

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.aiCredentialUpload.disabled",
            defaultValue: "Uploading AI account credentials is disabled by your organization."
        )
    }

    static func refusalError() -> ManagedPolicyRefusal {
        ManagedPolicyRefusal(message: disabledMessage)
    }
}

/// A managed-policy refusal thrown from a service boundary. Its description
/// is the user-facing message, so socket and CLI error paths print it as-is.
struct ManagedPolicyRefusal: Error, CustomStringConvertible, LocalizedError {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}

/// MDM master switch for cmux-managed Iroh networking.
enum ManagedIrohNetworkingPolicy {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableIrohNetworking`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableIrohNetworking)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.irohNetworking.disabled",
            defaultValue: "cmux relay networking is disabled by your organization."
        )
    }
}
