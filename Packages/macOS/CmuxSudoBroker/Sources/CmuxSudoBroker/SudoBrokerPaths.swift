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

    /// Request metadata and captured scripts.
    public var requests: URL { base.appendingPathComponent("requests", isDirectory: true) }

    /// Terminal result JSON and streamed output.
    public var results: URL { base.appendingPathComponent("results", isDirectory: true) }

    /// Durable lifecycle state.
    public var states: URL { base.appendingPathComponent("states", isDirectory: true) }

    /// Immutable copies of scripts that passed explicit review.
    public var approved: URL { base.appendingPathComponent("approved", isDirectory: true) }

    /// Completed request artifacts retained for audit and recovery.
    public var archive: URL { base.appendingPathComponent("archive", isDirectory: true) }

    /// Per-request advisory lock files.
    public var locks: URL { base.appendingPathComponent("locks", isDirectory: true) }

    /// The append-only audit log.
    public var auditLog: URL { base.appendingPathComponent("audit.log", isDirectory: false) }
}
