/// A validated source template that the host can copy into the user's sidebar directory.
public struct CustomSidebarTemplate: Equatable, Sendable {
    /// Suggested file stem for the generated sidebar.
    public let suggestedName: String

    /// File extension understood by the existing custom-sidebar validator.
    public let fileExtension: String

    /// Sidebar source copied into the user's custom-sidebar directory.
    public let source: String

    /// Creates a custom-sidebar template.
    ///
    /// - Parameters:
    ///   - suggestedName: Suggested file stem for the generated sidebar.
    ///   - fileExtension: File extension accepted by the custom-sidebar runtime.
    ///   - source: Sidebar source text.
    public init(suggestedName: String, fileExtension: String, source: String) {
        self.suggestedName = suggestedName
        self.fileExtension = fileExtension
        self.source = source
    }
}
