public import Foundation

/// Bundle-scoped filesystem locations for one sudo broker instance.
public struct SudoBrokerPaths: Sendable, Equatable {
    /// The root of this broker's private spool.
    public let base: URL

    /// Creates paths rooted at an injected directory.
    ///
    /// - Parameter base: A private application-support directory.
    public init(base: URL) {
        self.base = base.standardizedFileURL
    }

    /// Creates the spool for one stable or tagged app bundle.
    ///
    /// - Parameters:
    ///   - applicationSupportDirectory: The injected user application-support root.
    ///   - bundleIdentifier: The enclosing cmux app's bundle identifier.
    public init(applicationSupportDirectory: URL, bundleIdentifier: String) {
        let sanitizedScope = bundleIdentifier
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
                    ? String(scalar)
                    : "_"
            }
            .joined()
        let scope = sanitizedScope.isEmpty || sanitizedScope == "." || sanitizedScope == ".."
            ? "com.cmuxterm.app"
            : sanitizedScope
        base = applicationSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sudo", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
            .standardizedFileURL
    }

    /// Request metadata and captured scripts.
    public var requests: URL { base.appendingPathComponent("requests", isDirectory: true) }

    /// Terminal result JSON and streamed output.
    public var results: URL { base.appendingPathComponent("results", isDirectory: true) }

    /// Durable lifecycle state.
    public var states: URL { base.appendingPathComponent("states", isDirectory: true) }

    /// Runner manifests written only after explicit approval.
    public var executions: URL { base.appendingPathComponent("executions", isDirectory: true) }

    /// Immutable copies of scripts that passed explicit review.
    public var approved: URL { base.appendingPathComponent("approved", isDirectory: true) }

    /// Completed request artifacts retained for audit and recovery.
    public var archive: URL { base.appendingPathComponent("archive", isDirectory: true) }

    /// Per-request advisory lock files.
    public var locks: URL { base.appendingPathComponent("locks", isDirectory: true) }

    /// The append-only audit log.
    public var auditLog: URL { base.appendingPathComponent("audit.log", isDirectory: false) }
}
