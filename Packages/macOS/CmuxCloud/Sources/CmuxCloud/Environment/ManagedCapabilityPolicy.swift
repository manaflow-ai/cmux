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
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedRemoteConnectionsPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableRemoteConnections`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableRemoteConnections)
    }

    public static var isEnabled: Bool { !isDisabled }

    /// The message shown wherever a refusal surfaces to the user.
    public static var disabledMessage: String {
        String(
            localized: "managedPolicy.remoteConnections.disabled",
            defaultValue: "Remote connections are disabled by your organization."
        )
    }
}

/// MDM master switch for cmux-mediated file transfer.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedFileTransferPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableFileTransfer`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableFileTransfer)
    }

    public static var isEnabled: Bool { !isDisabled }

    public static var disabledMessage: String {
        String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        )
    }

    /// The failure handed to upload callers. An `NSError` rather than a new
    /// `RemoteDropUploadError` case, so the shared package enum keeps its
    /// exhaustive switches intact.
    public static func refusalError() -> NSError {
        NSError(
            domain: refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: disabledMessage]
        )
    }

    static let refusalErrorDomain = "cmux.managedPolicy.fileTransfer"

    /// Whether `error` is this policy's refusal (as opposed to a transport
    /// failure), so a drop or paste handler can explain it instead of beeping.
    public static func isRefusal(_ error: Error) -> Bool {
        (error as NSError).domain == refusalErrorDomain
    }

    /// Tells the user why the drop or paste did nothing. The failure handlers
    /// otherwise reduce every upload error to a beep, which would leave a
    /// managed refusal indistinguishable from a broken connection. Callable
    /// from any context: the alert is presented on the main actor.
    public static func presentRefusal() {
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
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedCloudPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableCloud`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableCloud)
    }

    public static var isEnabled: Bool { !isDisabled }

    /// The stable socket error code every Cloud refusal carries.
    public static let socketErrorCode = "cloud_disabled"

    public static var disabledMessage: String {
        String(
            localized: "cloud.managed.disabled",
            defaultValue: "Cloud Machines are disabled by your administrator."
        )
    }
}

/// MDM master switch for uploading local AI credentials (Claude/Codex OAuth
/// tokens, Anthropic/OpenAI API keys) to the cmux tenant. Independent of
/// `DisableCloud`, which already refuses the same families.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedAICredentialUploadPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableAICredentialUpload`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableAICredentialUpload)
    }

    public static var isEnabled: Bool { !isDisabled }

    public static let socketErrorCode = "ai_credential_upload_disabled"

    public static var disabledMessage: String {
        String(
            localized: "managedPolicy.aiCredentialUpload.disabled",
            defaultValue: "Uploading AI account credentials is disabled by your organization."
        )
    }

    public static func refusalError() -> ManagedPolicyRefusal {
        ManagedPolicyRefusal(message: disabledMessage)
    }
}

/// A managed-policy refusal thrown from a service boundary. Its description
/// is the user-facing message, so socket and CLI error paths print it as-is.
public struct ManagedPolicyRefusal: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }

    public init(
        message: String
    ) {
        self.message = message
    }
}

/// MDM master switch for cmux-managed Iroh networking.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum ManagedIrohNetworkingPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableIrohNetworking`.
    public static var isDisabled: Bool {
        return policy.isEnforced(.disableIrohNetworking)
    }

    public static var isEnabled: Bool { !isDisabled }

    public static var disabledMessage: String {
        String(
            localized: "managedPolicy.irohNetworking.disabled",
            defaultValue: "cmux relay networking is disabled by your organization."
        )
    }
}
