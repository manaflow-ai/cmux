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
/// (`FeatureRemoteStore`, CmuxNextFeatures), adapted at the composition root.
/// Called off the main actor; the document applies at the next launch.
nonisolated public protocol FlagsDocumentReceiving: Sendable {
    /// The ETag of the document last received, applied or not (nil: none).
    func lastETag() async -> String?
    func receive(_ document: VerifiedFlagsDocument) async
}
