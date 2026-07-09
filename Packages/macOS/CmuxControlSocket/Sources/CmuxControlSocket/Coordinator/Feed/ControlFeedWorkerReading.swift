public import Foundation

/// The live-state seam the worker-lane feed/feedback commands read and drive
/// through (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`, `feedback.submit`).
///
/// These commands run on the nonisolated socket-worker lane and block the
/// worker thread (the legacy `TerminalController.v2FeedPush` /
/// `v2FeedbackSubmit` bodies were synchronous `nonisolated` funcs that blocked
/// on `FeedCoordinator.ingestBlocking` and a `DispatchSemaphore`). The package
/// worker (``ControlFeedWorker``) owns the wire structure (method routing,
/// parameter validation, the exact error strings, and the result payloads); the
/// irreducibly app-coupled actions — decoding the workstream event, publishing
/// to `CmuxEventBus`, the iMessage-mode side effects, the blocking
/// `FeedCoordinator` ingest, delivering replies, and submitting feedback — stay
/// app-side behind this seam.
///
/// ## Isolation
///
/// `Sendable` and synchronous, NOT `@MainActor` and NOT `async`. The conformer
/// (`TerminalControllerFeedWorkerReading`) holds the controller weakly and hops
/// to the main actor internally exactly where the legacy bodies did
/// (`v2MainSync` / `DispatchQueue.main.async` / `MainActor.assumeIsolated`), so
/// the worker thread keeps blocking on the same waits and the wire bytes are
/// byte-identical. The synchronous surface preserves the legacy blocking
/// semantics (a `feed.push` with `wait_timeout_seconds > 0` parks the worker
/// thread until the user replies or the timeout elapses; `feedback.submit`
/// blocks up to 35 seconds).
public protocol ControlFeedWorkerReading: Sendable {
    /// Decodes, publishes, applies side effects for, and blocking-ingests a
    /// `feed.push` event, returning the result payload to encode.
    ///
    /// Mirrors the legacy `v2FeedPush` core after the wait-timeout parse and
    /// event-presence checks: publish `received`, apply the iMessage-mode side
    /// effects, note the hook event on the chat transcript service, block on
    /// `FeedCoordinator.ingestBlocking`, publish `completed` with the result,
    /// and return the same `FeedSocketEncoding.payload(for:)` dictionary.
    ///
    /// - Parameters:
    ///   - eventPayload: The `event` object the worker resolved (either the
    ///     nested `event` dict or the inline params), as ``JSONValue``s.
    ///   - waitTimeoutSeconds: The validated wait timeout in seconds.
    /// - Returns: `.delivered` with the result payload on success, or
    ///   `.decodeFailed` carrying the `String(describing:)` of the decode error
    ///   so the worker can build the byte-identical
    ///   `"feed.push event failed to decode: …"` message.
    func pushEvent(
        eventPayload: [String: JSONValue],
        waitTimeoutSeconds: TimeInterval
    ) -> ControlFeedPushOutcome

    /// Delivers a permission decision to the pending `feed.push` waiter.
    ///
    /// - Parameters:
    ///   - requestId: The `request_id` the reply targets.
    ///   - modeRawValue: The validated `mode` raw value (one of
    ///     `once|always|all|bypass|deny`).
    func deliverPermissionReply(requestId: String, modeRawValue: String)

    /// Delivers a question decision to the pending `feed.push` waiter.
    ///
    /// - Parameters:
    ///   - requestId: The `request_id` the reply targets.
    ///   - selections: The chosen option ids.
    func deliverQuestionReply(requestId: String, selections: [String])

    /// Delivers an exit-plan decision to the pending `feed.push` waiter.
    ///
    /// - Parameters:
    ///   - requestId: The `request_id` the reply targets.
    ///   - modeRawValue: The validated `mode` raw value (one of
    ///     `ultraplan|bypassPermissions|autoAccept|manual|deny`).
    ///   - feedback: The optional free-text feedback, forwarded verbatim.
    func deliverExitPlanReply(requestId: String, modeRawValue: String, feedback: String?)

    /// Submits feedback through the composer, blocking until it completes or the
    /// legacy 35-second timeout elapses.
    ///
    /// Mirrors `v2FeedbackSubmit` after the `FeedbackSubmissionRequest` parse:
    /// runs the async `FeedbackComposerBridge().submit` on a `Task`, blocks the
    /// worker thread on a `DispatchSemaphore`, and maps the bridge error cases
    /// to the legacy result codes.
    ///
    /// - Parameters:
    ///   - email: The validated submitter email.
    ///   - message: The validated message body.
    ///   - imagePaths: The optional attachment image paths.
    /// - Returns: The submission outcome.
    func submitFeedback(
        email: String,
        message: String,
        imagePaths: [String]
    ) -> ControlFeedbackSubmitOutcome
}

/// The outcome of a worker-lane `feed.push` ingest.
public enum ControlFeedPushOutcome: Sendable {
    /// The event was decoded and ingested; carries the result payload to encode
    /// (the ``JSONValue`` twin of the `FeedSocketEncoding.payload(for:)`
    /// dictionary).
    case delivered(payload: [String: JSONValue])
    /// The event failed to decode; carries `String(describing:)` of the decode
    /// error for the byte-identical legacy message.
    case decodeFailed(errorDescription: String)
}

/// The outcome of a worker-lane `feedback.submit`.
public enum ControlFeedbackSubmitOutcome: Sendable {
    /// Submitted successfully with the given attachment count.
    case submitted(attachmentCount: Int)
    /// A validation failure (`invalid_params`) with the bridge's message.
    case invalidParams(message: String)
    /// A submission failure (`request_failed`) with the bridge's message.
    case requestFailed(message: String)
    /// An unexpected failure (`internal_error`) with the error's message.
    case internalError(message: String)
    /// The submission did not complete within the 35-second timeout.
    case timedOut
}
