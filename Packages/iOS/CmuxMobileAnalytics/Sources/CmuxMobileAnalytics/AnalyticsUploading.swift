import Foundation

/// The network seam the emitter uses to ship a batch of events.
///
/// Injected so the ``AnalyticsEmitter`` actor can be unit-tested with a recording
/// fake instead of a live `URLSession`. The single method posts a batch and
/// reports the outcome so the emitter can decide whether to retry, drop, or
/// requeue.
public protocol AnalyticsUploading: Sendable {
    /// Posts a batch of events to the capture endpoint.
    ///
    /// - Parameter events: The events to upload, oldest first.
    /// - Returns: The ``AnalyticsUploadResult`` describing whether the batch was
    ///   accepted, should be retried, or should be permanently dropped.
    func upload(_ events: [AnalyticsEvent]) async -> AnalyticsUploadResult

    /// Sends an identify call, associating an anonymous id with a user id.
    ///
    /// - Parameters:
    ///   - userID: The stable user identifier, or `nil` to reset to anonymous.
    ///   - anonymousID: The prior anonymous id to alias, if any.
    ///   - properties: Person properties to set, rendered JSON-safe.
    /// - Returns: The ``AnalyticsUploadResult`` for the identify request.
    func identify(
        userID: String?,
        anonymousID: String?,
        properties: [String: any Sendable]
    ) async -> AnalyticsUploadResult
}

/// The outcome of an upload attempt.
public enum AnalyticsUploadResult: Sendable, Equatable {
    /// The server accepted the batch; drop it from the buffer.
    case accepted
    /// A transient failure (network error, 5xx); requeue and retry later.
    case retry
    /// A permanent failure (4xx); drop the batch, retrying won't help.
    case drop
}
