/// Foreground colors for every syntax token kind.
public struct FilePreviewSyntaxPalette: Equatable, Sendable {
    private let keyword: FilePreviewSyntaxColor
    private let type: FilePreviewSyntaxColor
    private let string: FilePreviewSyntaxColor
    private let number: FilePreviewSyntaxColor
    private let comment: FilePreviewSyntaxColor
    private let function: FilePreviewSyntaxColor
    private let attribute: FilePreviewSyntaxColor

    init(
        keyword: FilePreviewSyntaxColor,
        type: FilePreviewSyntaxColor,
        string: FilePreviewSyntaxColor,
        number: FilePreviewSyntaxColor,
        comment: FilePreviewSyntaxColor,
        function: FilePreviewSyntaxColor,
        attribute: FilePreviewSyntaxColor
    ) {
        self.keyword = keyword
        self.type = type
        self.string = string
        self.number = number
        self.comment = comment
        self.function = function
        self.attribute = attribute
    }

    /// Returns the foreground color for `kind`.
    ///
    /// - Parameter kind: A highlighted token classification.
    /// - Returns: The palette's color for that classification.
    public func color(for kind: FilePreviewSyntaxTokenKind) -> FilePreviewSyntaxColor {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .string: string
        case .number: number
        case .comment: comment
        case .function: function
        case .attribute: attribute
        }
    }
}
