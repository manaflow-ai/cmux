/// The text-box draft fields the session autosave fingerprint folds into its
/// hash, flattened off the app-target `SessionTextBoxInputDraftSnapshot`.
///
/// Carries only the values the legacy `TabManager.hashTextBoxDraftSnapshot`
/// (and its `hashTextBoxAttachmentSnapshot` helper) combined, in order. Each
/// part's `kind.rawValue` is resolved to a `String` app-side so the package
/// needs no `SessionTextBoxInputDraftPart.Kind`. The app-side
/// ``SessionFingerprintHosting`` witness maps the live snapshot into this value.
public struct SessionFingerprintTextBoxDraftSnapshot: Sendable, Equatable {
    /// A single flattened text-box draft part (text or attachment).
    public struct Part: Sendable, Equatable {
        /// Legacy `SessionTextBoxInputDraftPart.kind.rawValue`
        /// (`"text"` or `"attachment"`), resolved app-side.
        public let kindRawValue: String
        /// Legacy `SessionTextBoxInputDraftPart.text`.
        public let text: String?
        /// Legacy `SessionTextBoxInputDraftPart.attachment`, flattened.
        public let attachment: Attachment?

        /// Creates a flattened draft part.
        public init(kindRawValue: String, text: String?, attachment: Attachment?) {
            self.kindRawValue = kindRawValue
            self.text = text
            self.attachment = attachment
        }
    }

    /// A flattened text-box draft attachment.
    public struct Attachment: Sendable, Equatable {
        /// Legacy `SessionTextBoxInputAttachmentSnapshot.displayName`.
        public let displayName: String
        /// Legacy `SessionTextBoxInputAttachmentSnapshot.submissionText`.
        public let submissionText: String
        /// Legacy `SessionTextBoxInputAttachmentSnapshot.submissionPath`.
        public let submissionPath: String
        /// Legacy `SessionTextBoxInputAttachmentSnapshot.localPath`.
        public let localPath: String?
        /// Legacy `SessionTextBoxInputAttachmentSnapshot.cleanupLocalPathWhenDisposed`.
        public let cleanupLocalPathWhenDisposed: Bool

        /// Creates a flattened attachment.
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

    /// Legacy `SessionTextBoxInputDraftSnapshot.isActive`.
    public let isActive: Bool
    /// Legacy `SessionTextBoxInputDraftSnapshot.parts`, flattened.
    public let parts: [Part]

    /// Creates a flattened text-box draft fingerprint input.
    public init(isActive: Bool, parts: [Part]) {
        self.isActive = isActive
        self.parts = parts
    }
}
