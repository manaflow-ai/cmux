import Foundation

/// When any attachment upload's acked bytes last advanced: a chat prompt held for the link
/// waits while this keeps moving (`AcpmuxSessionSource.expireHeldPrompts`). Set by
/// `AttachmentUploadClient` (where the upload engine exists); nil until an upload advances.
@MainActor
public enum UploadActivity {
    public static var lastAdvance: ContinuousClock.Instant?
}
