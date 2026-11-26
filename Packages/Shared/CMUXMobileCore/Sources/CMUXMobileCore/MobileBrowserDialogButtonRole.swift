/// The visual and semantic role of a mirrored browser dialog button.
public enum MobileBrowserDialogButtonRole: String, Codable, Equatable, Sendable {
    /// The dialog's preferred affirmative action.
    case `default`
    /// An action that cancels or declines the request.
    case cancel
    /// An irreversible or security-sensitive action.
    case destructive
}
