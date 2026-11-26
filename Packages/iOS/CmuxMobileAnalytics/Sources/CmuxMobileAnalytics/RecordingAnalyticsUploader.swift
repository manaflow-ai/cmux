import Foundation

/// An ``AnalyticsUploading`` that records what it was asked to upload.
///
/// Backs the emitter's unit tests: it captures every batch and identify call and
/// returns a programmable ``AnalyticsUploadResult`` so tests can drive the
/// accept/retry/drop branches deterministically without a network.
public actor RecordingAnalyticsUploader: AnalyticsUploading {
    /// Every batch passed to ``upload(_:)``, in call order.
    public private(set) var uploadedBatches: [[AnalyticsEvent]] = []
    /// Every identify call, as `(userID, anonymousID)`.
    public private(set) var identifyCalls: [(userID: String?, anonymousID: String?)] = []
    private var nextResult: AnalyticsUploadResult

    /// Creates a recording uploader.
    /// - Parameter result: The result returned from every call. Default `.accepted`.
    public init(result: AnalyticsUploadResult = .accepted) {
        self.nextResult = result
    }

    /// Sets the result returned by subsequent calls.
    public func setResult(_ result: AnalyticsUploadResult) {
        nextResult = result
    }

    /// The flattened list of every uploaded event across all batches.
    public var uploadedEvents: [AnalyticsEvent] {
        uploadedBatches.flatMap { $0 }
    }

    public func upload(_ events: [AnalyticsEvent]) async -> AnalyticsUploadResult {
        uploadedBatches.append(events)
        return nextResult
    }

    public func identify(
        userID: String?,
        anonymousID: String?,
        properties: [String: any Sendable]
    ) async -> AnalyticsUploadResult {
        identifyCalls.append((userID, anonymousID))
        return nextResult
    }
}
