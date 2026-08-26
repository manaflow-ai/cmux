/// Normalized agent presentation that retains the provider value verbatim.
public struct NestedAgentStatus: Codable, Equatable, Sendable {
    /// Known cmux presentation category.
    public let presentation: NestedStatusPresentation

    /// Original provider state preserved byte-for-byte, including unknown future values.
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

    /// Compares the presentation and exact provider status bytes.
    public static func == (lhs: NestedAgentStatus, rhs: NestedAgentStatus) -> Bool {
        lhs.presentation == rhs.presentation
            && ExactUTF8String(lhs.providerRawValue) == ExactUTF8String(rhs.providerRawValue)
    }

    /// Decodes a status while preserving the original provider bytes.
    ///
    /// - Parameter decoder: Decoder containing the normalized and raw status.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try container.decode(
            NestedStatusPresentation.self,
            forKey: .presentation
        )
        providerRawValue = try container.decode(
            ExactUTF8String.self,
            forKey: .providerRawValue
        ).value
    }

    /// Encodes a status with a byte-exact provider value.
    ///
    /// - Parameter encoder: Encoder receiving the normalized and raw status.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(
            ExactUTF8String(providerRawValue),
            forKey: .providerRawValue
        )
    }

    private enum CodingKeys: String, CodingKey {
        case presentation
        case providerRawValue
    }
}
