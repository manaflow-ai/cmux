public import Foundation

/// The parsed positional arguments for the v1 `notify_target_async` command.
///
/// A pure, `Sendable` value produced by ``parse(_:)`` from the raw v1 argument
/// string. The tokenizer is byte-faithful to the legacy god-file
/// `notifyTargetQueued(_:)` argument parsing: the argument string is whitespace
/// trimmed; an empty result is a usage failure; otherwise it is split on spaces
/// into at most three parts which must number exactly three; the first two parts
/// must each parse as a `UUID` (workspace then surface), and the third part is
/// whitespace trimmed and must be non-empty. The app-side `notifyTargetQueued`
/// witness consumes ``tabId`` and ``surfaceId`` and parses ``payload`` into a
/// ``ControlNotificationPayload`` before enqueueing the notification.
public struct ControlNotifyTargetQueuedRequest: Sendable, Equatable {
    /// The target workspace identifier (`<workspace_uuid>`).
    public let tabId: UUID
    /// The target surface identifier (`<surface_uuid>`).
    public let surfaceId: UUID
    /// The trimmed, non-empty `<title>|<subtitle>|<body>` payload string.
    public let payload: String

    /// Creates a parsed `notify_target_async` request value.
    ///
    /// - Parameters:
    ///   - tabId: The target workspace identifier.
    ///   - surfaceId: The target surface identifier.
    ///   - payload: The trimmed, non-empty payload string.
    public init(tabId: UUID, surfaceId: UUID, payload: String) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.payload = payload
    }

    /// A `notify_target_async` argument-parse failure carrying the verbatim v1
    /// wire error string to return to the client.
    public struct ParseError: Error, Sendable, Equatable {
        /// The wire error message (e.g. `"ERROR: notify_target_async requires
        /// workspace_uuid to be a UUID"`).
        public let message: String

        /// Creates a parse error.
        ///
        /// - Parameter message: The verbatim wire error message.
        public init(message: String) {
            self.message = message
        }
    }

    /// Parses the raw `notify_target_async` argument string into a request.
    ///
    /// Byte-faithful to the legacy `notifyTargetQueued(_:)` parsing: the argument
    /// string is whitespace trimmed; an empty result returns the usage failure;
    /// otherwise it is split on spaces with at most two splits and must yield
    /// exactly three parts; the first two parts must each parse as a `UUID`
    /// (otherwise the respective workspace/surface failure is returned); the
    /// third part is whitespace trimmed and must be non-empty (otherwise the
    /// usage failure is returned).
    ///
    /// - Parameter args: The raw argument substring following `notify_target_async`.
    /// - Returns: The parsed request, or a ``ParseError`` with the wire message.
    public static func parse(_ args: String) -> Result<ControlNotifyTargetQueuedRequest, ParseError> {
        let usageMessage = "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ParseError(message: usageMessage))
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return .failure(ParseError(message: usageMessage))
        }
        guard let tabId = UUID(uuidString: parts[0]) else {
            return .failure(ParseError(message: "ERROR: notify_target_async requires workspace_uuid to be a UUID"))
        }
        guard let surfaceId = UUID(uuidString: parts[1]) else {
            return .failure(ParseError(message: "ERROR: notify_target_async requires surface_uuid to be a UUID"))
        }

        let payload = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return .failure(ParseError(message: usageMessage))
        }

        return .success(
            ControlNotifyTargetQueuedRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                payload: payload
            )
        )
    }
}
