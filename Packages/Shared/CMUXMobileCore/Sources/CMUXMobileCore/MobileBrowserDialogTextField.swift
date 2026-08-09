/// Text-entry metadata for a mirrored browser dialog.
public struct MobileBrowserDialogTextField: Codable, Equatable, Sendable {
    /// Mac-provided placeholder displayed verbatim, when present.
    public let placeholder: String?
    /// Initial field value, when present.
    public let initial: String?
    /// Whether entered text must be obscured and treated as sensitive.
    public let secure: Bool

    /// Creates mirrored text-entry metadata.
    /// - Parameters:
    ///   - placeholder: Mac-provided placeholder displayed verbatim.
    ///   - initial: Initial field value.
    ///   - secure: Whether entered text must be obscured and treated as sensitive.
    public init(placeholder: String?, initial: String?, secure: Bool) {
        self.placeholder = placeholder
        self.initial = initial
        self.secure = secure
    }
}
