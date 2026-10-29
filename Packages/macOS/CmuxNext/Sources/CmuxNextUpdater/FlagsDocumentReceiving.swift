public import Foundation

/// A `notes/flags.json` whose `.sig` verified with the notes' content key. Only
/// ``FlagsDocumentFetch`` makes one, so a receiver never sees unverified bytes.
nonisolated public struct VerifiedFlagsDocument: Sendable, Equatable {
    public let data: Data
    /// The signature text (base64), kept with the bytes so a reader can verify the stored copy again.
    public let signature: String
    /// The server's ETag of `data`, sent as `If-None-Match` next launch.
    public let etag: String?

    init(data: Data, signature: String, etag: String?) {
        self.data = data
        self.signature = signature
        self.etag = etag
    }
}

/// Where a verified flags document goes: the features' remote store
/// (`FeatureRemoteStore`, CmuxNextFeatures), adapted at the composition root and
/// passed to `UpdaterService`'s `flagsReceiver`.
/// Called off the main actor; the document applies at the next launch.
nonisolated public protocol FlagsDocumentReceiving: Sendable {
    /// The ETag of the document last received, applied or not (nil: none).
    func lastETag() async -> String?
    func receive(_ document: VerifiedFlagsDocument) async
    /// Every run's outcome, after ``receive(_:)`` when there was a new document.
    /// ``FlagsDocumentFetch/Outcome/attempt`` says how it counts for the
    /// fetch-failure streak (a 304 is a successful fetch, as in Chrome);
    /// ``FlagsDocumentFetch/Outcome/disabledByPolicy`` means the managed policy
    /// turns remote flags off, so a stored document must not apply either.
    func fetchCompleted(_ outcome: FlagsDocumentFetch.Outcome) async
}
