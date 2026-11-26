/// The typed transport failure a stream producer can report, at the
/// granularity the event-stream reconnect decision reasons about.
///
/// The CLI maps its richer `CLIError.SocketFailureKind` onto this vocabulary;
/// keeping the decision input small lets the decision stay unit-testable without
/// the CLI target.
public enum EventStreamSocketFailureKind: Equatable, Sendable {
    /// Setting the socket's receive timeout failed with EINVAL, which macOS
    /// returns once the peer has closed the connection (#12756).
    case receiveTimeoutConfiguration
}

/// An event-stream failure as the `cmux events --reconnect` loop sees it,
/// reduced to the inputs its retry decision needs.
///
/// Localization and `CLIError` mapping remain the CLI's responsibility,
/// mirroring how wire-level classification stays in this package.
public struct EventStreamFailure: Equatable, Sendable {
    /// The typed transport failure, when the producer could classify one.
    public var socketFailureKind: EventStreamSocketFailureKind?
    /// The failure's display message, matched against the legacy
    /// connection-failure markers. Empty when the producer had no message.
    public var message: String
    /// `String(describing:)` of an error that carried no message at all,
    /// matched against the coarsest reset/timeout markers. Ignored when the
    /// producer had a typed message.
    public var untypedDescription: String?

    public init(
        socketFailureKind: EventStreamSocketFailureKind? = nil,
        message: String,
        untypedDescription: String? = nil
    ) {
        self.socketFailureKind = socketFailureKind
        self.message = message
        self.untypedDescription = untypedDescription
    }

    /// Whether `cmux events --reconnect` may retry this failure.
    ///
    /// A typed ``EventStreamSocketFailureKind`` is authoritative (a
    /// receive-timeout configuration failure is transient without consulting
    /// the message, so event *content* that merely mentions errno strings can
    /// never be mistaken for it), while the legacy connection-failure markers
    /// stay best-effort over the message text.
    public var isTransient: Bool {
        if socketFailureKind == .receiveTimeoutConfiguration {
            return true
        }

        let loweredMessage = message.lowercased()
        let transientMarkers = [
            "socket not found",
            "failed to connect",
            "event stream closed",
            "event stream socket read error",
            "timed out waiting for event stream frame",
            "stream request timed out",
            "failed to write stream request",
            "broken pipe",
            "connection reset",
            "connection refused",
            "errno 32",
            "errno 35",
            "errno 54",
            "errno 57",
            "errno 60",
            "errno 61"
        ]
        if transientMarkers.contains(where: loweredMessage.contains) {
            return true
        }

        guard let untypedDescription else { return false }
        let loweredDescription = untypedDescription.lowercased()
        return loweredDescription.contains("connection reset")
            || loweredDescription.contains("connection refused")
            || loweredDescription.contains("broken pipe")
            || loweredDescription.contains("timed out")
    }
}
