public import Foundation

/// Thrown to a PTY bridge start when its remote session is parked.
///
/// Unlike the transient "remote daemon is not ready", nothing will make a
/// parked session ready without an explicit reconnect, so callers must stop
/// waiting and retrying and present ``detail`` instead
/// (https://github.com/manaflow-ai/cmux/issues/12813).
public struct RemoteSessionParkedError: LocalizedError, Equatable, Sendable {
    /// App-localized, user-facing reason and next step; identical to the
    /// detail published with the session's suspended state.
    public let detail: String

    /// Creates the error for a session parked with `detail`.
    public init(detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? { detail }
}
