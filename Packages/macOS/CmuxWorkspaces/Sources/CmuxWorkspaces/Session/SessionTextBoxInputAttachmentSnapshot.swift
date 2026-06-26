/// A persisted text-box draft attachment inside a session snapshot.
///
/// A pure leaf value carrying the attachment's `displayName`, the
/// `submissionText`/`submissionPath` used when the draft is submitted, an
/// optional durable `localPath`, and whether that local file should be removed
/// when the attachment is disposed. The app-side `TextBoxAttachment` bridge
/// (an extension on this type) converts to and from the live attachment; the
/// on-disk wire format is owned by the app's draft snapshots and stays
/// byte-identical to the legacy app-target definition.
public struct SessionTextBoxInputAttachmentSnapshot: Codable, Equatable, Sendable {
    /// User-visible attachment name.
    public var displayName: String
    /// Text inserted into the draft when submitted.
    public var submissionText: String
    /// Path inserted into the draft when submitted.
    public var submissionPath: String
    /// Optional durable local file path backing the attachment.
    public var localPath: String?
    /// Whether the local file is removed when the attachment is disposed.
    public var cleanupLocalPathWhenDisposed: Bool

    /// Creates a persisted text-box attachment snapshot.
    public init(
        displayName: String,
        submissionText: String,
        submissionPath: String,
        localPath: String?,
        cleanupLocalPathWhenDisposed: Bool
    ) {
        self.displayName = displayName
        self.submissionText = submissionText
        self.submissionPath = submissionPath
        self.localPath = localPath
        self.cleanupLocalPathWhenDisposed = cleanupLocalPathWhenDisposed
    }
}
