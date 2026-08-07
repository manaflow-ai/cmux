/// Normalized agent presentation that retains the provider value verbatim.
public struct NestedAgentStatus: Codable, Equatable, Sendable {
    /// Known cmux presentation category.
    public let presentation: NestedStatusPresentation

    /// Original provider state, including unknown future values.
    public let providerRawValue: String

    /// Creates a normalized and raw status pair.
    ///
    /// - Parameters:
    ///   - presentation: Known cmux presentation category.
    ///   - providerRawValue: Original provider state.
    public init(presentation: NestedStatusPresentation, providerRawValue: String) {
        self.presentation = presentation
        self.providerRawValue = providerRawValue
    }
}
