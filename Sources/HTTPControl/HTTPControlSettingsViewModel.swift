import Foundation

/// Binding view model for the HTTP control Settings pane.
///
/// Wraps an ``HTTPControlSettings`` so a SwiftUI ``Form`` can edit the
/// individual knobs via `@Published` properties, then write the changes
/// back atomically via ``commit()``. Token rotation goes through
/// ``rotateToken()`` which also returns the new token to the view so
/// the new value can be shown to the user immediately.
///
/// The view model also exposes the spec §5.4 and §8.3 safety strings:
/// ``tcpSafetyWarning`` (RCE warning when TCP is enabled) and
/// ``rawInputWarning`` (OSC 52 / DSR / DECRQSS reflection-injection
/// warning when raw input is allowed). Both are localized via
/// `String(localized:defaultValue:)`.
@MainActor
public final class HTTPControlSettingsViewModel: ObservableObject {
    /// Enable / disable the HTTP control listener.
    @Published public var enabled: Bool
    /// Transport selection (TCP loopback vs UDS).
    @Published public var transport: HTTPControlSettings.Transport
    /// TCP loopback port.
    @Published public var tcpPort: Int
    /// Filesystem path for the AF_UNIX socket.
    @Published public var udsPath: String
    /// Whether `type=raw` input payloads are accepted (D15).
    @Published public var allowRawInput: Bool
    /// Audit log file path. Empty means "use the default under support
    /// directory" — see ``HTTPControlSettings/auditLogPath``.
    @Published public var auditLogPath: String

    /// Optional restart hook called from ``rotateToken()``. The
    /// lifecycle wire-up (Task 1.22) plugs in
    /// ``HTTPControlLifecycle/rotateTokenAndRestart()`` here so token
    /// rotation also invalidates running connections (spec §16.3).
    public var onTokenRotated: ((String) -> Void)?

    private let settings: HTTPControlSettings

    /// Snapshots all knobs out of `settings` so the bound `@Published`
    /// values match the persisted state at view-open time.
    public init(settings: HTTPControlSettings) {
        self.settings = settings
        self.enabled = settings.enabled
        self.transport = settings.transport
        self.tcpPort = settings.tcpPort
        self.udsPath = settings.udsPath
        self.allowRawInput = settings.allowRawInput
        let stored = settings.auditLogPathString
        self.auditLogPath = stored.isEmpty
            ? settings.auditLogPath.path
            : stored
    }

    /// Persists the current `@Published` values back into the
    /// underlying ``HTTPControlSettings``. Safe to call from
    /// `.onDisappear` or an explicit Save button.
    public func commit() throws {
        settings.enabled = enabled
        settings.transport = transport
        settings.tcpPort = tcpPort
        settings.udsPath = udsPath
        settings.allowRawInput = allowRawInput
        // Default-derived path is treated as "no override"; setting it
        // explicitly here would pin the same path even if support
        // directory changes later. Only round-trip a user-typed value.
        let defaultDerived = settings.auditLogPath.path
        if auditLogPath.isEmpty || auditLogPath == defaultDerived {
            // No override.
            if !settings.auditLogPathString.isEmpty,
               settings.auditLogPathString == defaultDerived {
                settings.auditLogPathString = ""
            }
        } else {
            settings.auditLogPathString = auditLogPath
        }
    }

    /// Generates a fresh token, invokes ``onTokenRotated`` so the
    /// lifecycle can restart the listener, and returns the new token
    /// for display in the pane.
    @discardableResult
    public func rotateToken() throws -> String {
        let t = try settings.rotateToken()
        onTokenRotated?(t)
        return t
    }

    /// Returns the current token (creating one if absent). The pane
    /// displays this on open so the user can copy without rotating.
    public func currentToken() throws -> String {
        try settings.ensureToken()
    }

    /// Spec §5.4 + §16 — TCP listener has no `LOCAL_PEERCRED` /
    /// process-ancestry check; any local process holding the token
    /// has full RCE on the user's account.
    public var tcpSafetyWarning: String {
        String(
            localized: "httpControl.warning.tcp",
            defaultValue: "Enabling TCP grants any local process holding the token full shell access (RCE). Use UDS for stronger isolation."
        )
    }

    /// Spec §8.3 + §16.8 — `type=raw` lets clients send OSC 52
    /// (clipboard reads/writes) and DSR / DECRQSS terminal queries
    /// whose replies are injected back into stdin (reflection
    /// injection).
    public var rawInputWarning: String {
        String(
            localized: "httpControl.warning.raw",
            defaultValue: "Allowing type=raw enables OSC 52 clipboard access and DSR / DECRQSS terminal queries whose replies are injected as stdin — a reflection-injection vector. Keep disabled unless you trust every local process."
        )
    }
}
