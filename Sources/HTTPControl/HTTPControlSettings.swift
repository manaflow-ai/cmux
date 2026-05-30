import CmuxTerminalAccess
import Foundation

/// Persisted settings for the HTTP control surface (D2 single definition).
///
/// Instance class — **not** static `@AppStorage` — so tests and the
/// HTTP lifecycle can inject `supportDirectory` and `UserDefaults`.
/// Phase 1 binds the SwiftUI view to this type; Phase 1 does **not**
/// redefine it.
///
/// The on-disk token lives in a separate AppKit-free leaf type
/// (``HTTPControlTokenStore`` in `CmuxTerminalAccess`) so the token
/// behavior can be unit tested from `swift test` on the package.
/// This composer exposes the same `ensureToken()` / `rotateToken()`
/// surface the rest of the app expects.
///
/// Per D9 the bearer token is **never** injected into spawned PTY
/// child environments; only the HTTP listener reads the file. Per
/// E15 the UDS path setting is named ``udsPath`` (not
/// `unixSocketPath`).
public final class HTTPControlSettings {
    /// HTTP control transport selection (D2 inner enum).
    public enum Transport: String, Sendable {
        /// Listen on a TCP loopback port.
        case tcp
        /// Listen on a Unix domain socket.
        case uds
    }

    /// Application support directory. The token file and default
    /// audit log live below this path.
    public let supportDirectory: URL
    private let defaults: UserDefaults
    private let tokenStore: HTTPControlTokenStore

    /// Creates a settings instance bound to a support directory and
    /// a `UserDefaults` suite.
    ///
    /// - Parameters:
    ///   - supportDirectory: Directory containing the token file
    ///     (mode 0700 enforced on creation).
    ///   - defaults: `UserDefaults` instance for the boolean / int /
    ///     string knobs. Defaults to `.standard`.
    public init(supportDirectory: URL, defaults: UserDefaults = .standard) {
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.tokenStore = HTTPControlTokenStore(
            fileURL: supportDirectory.appendingPathComponent("http-control-token")
        )
    }

    // MARK: - Settings keys (per D2)

    /// Master switch for the HTTP control surface.
    public var enabled: Bool {
        get { defaults.bool(forKey: Self.kEnabled) }
        set { defaults.set(newValue, forKey: Self.kEnabled) }
    }

    /// Selected transport (TCP loopback or UDS).
    public var transport: Transport {
        get {
            Transport(rawValue: defaults.string(forKey: Self.kTransport) ?? Transport.tcp.rawValue)
                ?? .tcp
        }
        set { defaults.set(newValue.rawValue, forKey: Self.kTransport) }
    }

    /// TCP loopback port. Defaults to `49100` when unset.
    public var tcpPort: Int {
        get {
            let v = defaults.integer(forKey: Self.kTcpPort)
            return v > 0 ? v : 49100
        }
        set { defaults.set(newValue, forKey: Self.kTcpPort) }
    }

    /// Unix-socket path. Per Errata E15 the locked name is
    /// `udsPath`, not `unixSocketPath` — used consistently across
    /// settings, the SwiftUI view, and lifecycle wiring.
    public var udsPath: String {
        get { defaults.string(forKey: Self.kUDSPath) ?? "" }
        set { defaults.set(newValue, forKey: Self.kUDSPath) }
    }

    /// Whether the HTTP layer accepts `.raw` input payloads. Defaults
    /// to `false`. Wired into ``DefaultTerminalAccessService`` as the
    /// `allowRawInput` closure in Phase 1.
    public var allowRawInput: Bool {
        get { defaults.bool(forKey: Self.kAllowRawInput) }
        set { defaults.set(newValue, forKey: Self.kAllowRawInput) }
    }

    /// Audit log path. Per D4 the **path** is configurable; the
    /// logging itself is always-on for write paths.
    public var auditLogPath: URL {
        get {
            if let custom = defaults.string(forKey: Self.kAuditLogPath), !custom.isEmpty {
                return URL(fileURLWithPath: custom)
            }
            return supportDirectory.appendingPathComponent("http-control-audit.jsonl")
        }
        set {
            defaults.set(newValue.path, forKey: Self.kAuditLogPath)
        }
    }

    /// Raw string-backed view of ``auditLogPath`` used by the
    /// Settings view model. Empty string clears the override and
    /// falls back to the default support-directory path.
    public var auditLogPathString: String {
        get { defaults.string(forKey: Self.kAuditLogPath) ?? "" }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.kAuditLogPath)
            } else {
                defaults.set(newValue, forKey: Self.kAuditLogPath)
            }
        }
    }

    /// Timestamp of the last token rotation. `nil` if the token has
    /// never been rotated through this composer.
    public var tokenLastRotated: Date? {
        let v = defaults.double(forKey: Self.kTokenLastRotated)
        return v > 0 ? Date(timeIntervalSince1970: v) : nil
    }

    // MARK: - Token store (D2 — embedded behavior via composed leaf store)

    /// On-disk token file path.
    public var tokenFilePath: URL { tokenStore.fileURL }

    /// Returns the existing token, generating one (and creating the
    /// file with mode 0600) if absent. Delegates to
    /// ``HTTPControlTokenStore``. Per D9 the token is **never**
    /// injected into spawned PTY child environments.
    public func ensureToken() throws -> String {
        try tokenStore.ensureToken()
    }

    /// Generates a fresh token, atomically overwrites the file, and
    /// records the rotation timestamp in `UserDefaults`.
    @discardableResult
    public func rotateToken() throws -> String {
        let token = try tokenStore.rotateToken()
        defaults.set(Date().timeIntervalSince1970, forKey: Self.kTokenLastRotated)
        return token
    }

    // MARK: - UserDefaults keys

    private static let kEnabled = "httpControl.enabled"
    private static let kTransport = "httpControl.transport"
    private static let kTcpPort = "httpControl.tcpPort"
    private static let kUDSPath = "httpControl.udsPath"
    private static let kAllowRawInput = "httpControl.allowRawInput"
    private static let kAuditLogPath = "httpControl.auditLogPath"
    private static let kTokenLastRotated = "httpControl.tokenLastRotated"
}
