/// Localized errors returned by `workspace.font_size`.
public struct ControlWorkspaceFontSizeStrings: Sendable, Equatable {
    public let invalidParams: String
    public let unavailable: String
    public let notFound: String
    public let rejected: String

    public init(
        invalidParams: String,
        unavailable: String,
        notFound: String,
        rejected: String
    ) {
        self.invalidParams = invalidParams
        self.unavailable = unavailable
        self.notFound = notFound
        self.rejected = rejected
    }
}
