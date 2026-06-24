public import CmuxSessionIndex

/// App-resolved, localized strings the transcript preview renders.
///
/// `String(localized:)` must resolve against the host app bundle (this package's
/// `Bundle.module` lacks the session-index keys), so the app constructs this struct
/// with already-resolved values and hands it to ``SessionTranscriptPreviewView``.
/// `roleLabel` resolves the localized speaker label per role for the same reason;
/// the role's color/font presentation lives in the package (see
/// `SessionTranscriptRole` SwiftUI extension) because it carries no localization.
public struct SessionTranscriptPreviewStrings: Sendable {
    public let close: String
    public let resize: String
    public let loading: String
    public let noFile: String
    public let error: String
    public let empty: String
    /// Resolves the localized speaker label for a transcript role (app bundle).
    public let roleLabel: @Sendable (SessionTranscriptRole) -> String

    /// Creates the app-resolved strings bundle for the transcript preview.
    /// - Parameters:
    ///   - close: Accessibility/help text for the close affordance ("Close").
    ///   - resize: Help text for the resize handle ("Resize preview").
    ///   - loading: Status text while the transcript loads ("Loading…").
    ///   - noFile: Status text when no transcript file exists ("No transcript file").
    ///   - error: Status text when the transcript fails to load ("Couldn't load transcript").
    ///   - empty: Status text when the transcript has no previewable messages.
    ///   - roleLabel: Resolver for the localized per-role speaker label.
    public init(
        close: String,
        resize: String,
        loading: String,
        noFile: String,
        error: String,
        empty: String,
        roleLabel: @escaping @Sendable (SessionTranscriptRole) -> String
    ) {
        self.close = close
        self.resize = resize
        self.loading = loading
        self.noFile = noFile
        self.error = error
        self.empty = empty
        self.roleLabel = roleLabel
    }
}
