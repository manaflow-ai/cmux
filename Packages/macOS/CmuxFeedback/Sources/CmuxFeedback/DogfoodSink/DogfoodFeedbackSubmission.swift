import Foundation

/// The raw, un-capped fields of a dogfood feedback submission as decoded from
/// the wire. The caller (the macOS host RPC router) extracts these from the
/// inbound RPC params verbatim; the ``DogfoodFeedbackService`` is responsible
/// for capping, validating, and persisting them. Keeping the type a plain
/// `Sendable` value lets the whole submission cross into the detached writer
/// task without copying logic.
public struct DogfoodFeedbackSubmission: Sendable, Equatable {
    /// The free-form feedback text (`text` on the wire), un-capped.
    public var text: String
    /// The captured visible terminal text (`terminal_text` on the wire), un-capped.
    public var terminalText: String
    /// The build identifier the phone reported (`build_stamp` on the wire), un-capped.
    public var buildStamp: String
    /// The base64-encoded diagnostic blob (`diagnostic_blob_base64` on the
    /// wire), un-decoded.
    public var diagnosticBlobBase64: String

    /// Create a raw submission from the four wire fields.
    /// - Parameters:
    ///   - text: the free-form feedback text.
    ///   - terminalText: the captured visible terminal text.
    ///   - buildStamp: the reported build identifier.
    ///   - diagnosticBlobBase64: the base64-encoded diagnostic blob.
    public init(
        text: String,
        terminalText: String,
        buildStamp: String,
        diagnosticBlobBase64: String
    ) {
        self.text = text
        self.terminalText = terminalText
        self.buildStamp = buildStamp
        self.diagnosticBlobBase64 = diagnosticBlobBase64
    }
}
