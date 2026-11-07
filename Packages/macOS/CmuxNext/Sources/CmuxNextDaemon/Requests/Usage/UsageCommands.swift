public import Foundation

// Opt-in usage recording (cmux-tui crate `cmux-usage`): the shape of how cmux
// is used, never content. Every command is trusted local only; the daemon
// refuses them from a remote or WebSocket peer. A daemon older than these
// commands answers with an unknown-variant error, so callers treat a failure
// as "not recorded" and never retry in a loop.

/// `usage-record`: appends one batch of usage events to
/// `<usage dir>/<source>.jsonl`. Writes nothing while recording is off
/// (`written` is 0); a batch with any unknown field or event kind is refused
/// whole.
public struct UsageRecordRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// Events written; 0 while recording is off.
        public var written: Int
    }

    public static let command = "usage-record"
    /// The writer's file stem, e.g. `app-nightly` or `app-dev`.
    public var source: String
    /// JSON array text of `{"at": <unix ms>, "ev": {"t": ..., ...}}` objects.
    public var events: String

    public init(source: String, events: String) {
        self.source = source
        self.events = events
    }
}

/// `usage-set-enabled`: switches usage recording on or off (the
/// `<usage dir>/enabled` marker). Off keeps what was recorded.
public struct UsageSetEnabledRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The state now.
        public var on: Bool
        /// The usage folder.
        public var dir: String
    }

    public static let command = "usage-set-enabled"
    public var on: Bool

    public init(on: Bool) { self.on = on }
}

/// `usage-set-sharing`: switches sharing the usage record with the team on or
/// off (the `<usage dir>/share` marker `cmux usage upload` requires). On is
/// refused while recording is off; recording off also switches it off.
public struct UsageSetSharingRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The state now.
        public var on: Bool
        /// The usage folder.
        public var dir: String
    }

    public static let command = "usage-set-sharing"
    public var on: Bool

    public init(on: Bool) { self.on = on }
}

extension DaemonConnection {
    /// Appends one batch of usage events (`usage-record`); returns how many were written.
    @discardableResult
    public func recordUsage(source: String, events: String) async throws -> Int {
        try await request(UsageRecordRequest(source: source, events: events)).written
    }

    /// Switches usage recording on or off (`usage-set-enabled`).
    @discardableResult
    public func setUsageRecording(_ on: Bool) async throws -> UsageSetEnabledRequest.Response {
        try await request(UsageSetEnabledRequest(on: on))
    }

    /// Switches sharing the usage record on or off (`usage-set-sharing`).
    @discardableResult
    public func setUsageSharing(_ on: Bool) async throws -> UsageSetSharingRequest.Response {
        try await request(UsageSetSharingRequest(on: on))
    }
}
