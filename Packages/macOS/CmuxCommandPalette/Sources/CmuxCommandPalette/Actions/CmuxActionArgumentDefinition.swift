/// A stable argument contract shared by every presentation of a cmux action.
public struct CmuxActionArgumentDefinition: Sendable, Equatable {
    /// The value representation accepted on the wire and in configuration.
    public typealias ValueType = CmuxActionArgumentValueType

    /// Stable argument name.
    public let name: String
    /// Expected value representation.
    public let valueType: ValueType
    /// Whether automation callers must supply this argument.
    public let required: Bool
    /// Whether an explicitly supplied empty string is valid.
    public let allowsEmpty: Bool

    /// Creates a static action argument contract.
    ///
    /// - Parameters:
    ///   - name: The stable argument name.
    ///   - valueType: The accepted wire representation.
    ///   - required: Whether automation callers must supply the argument.
    ///   - allowsEmpty: Whether an explicitly supplied empty string is valid.
    public init(
        name: String,
        valueType: ValueType = .string,
        required: Bool = true,
        allowsEmpty: Bool = false
    ) {
        self.name = name
        self.valueType = valueType
        self.required = required
        self.allowsEmpty = allowsEmpty
    }
}
