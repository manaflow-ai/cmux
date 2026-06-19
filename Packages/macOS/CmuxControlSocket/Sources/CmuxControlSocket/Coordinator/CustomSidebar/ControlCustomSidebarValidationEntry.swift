/// Custom-sidebar validation entry shaped for control-socket wire payloads.
public struct ControlCustomSidebarValidationEntry: Equatable, Sendable {
    /// Sidebar name without a file extension.
    public let name: String

    /// Absolute path of the sidebar file represented by this entry.
    public let path: String

    /// Sidebar file kind raw value used on the socket wire.
    public let kind: String

    /// Whether the sidebar file passed validation.
    public let isValid: Bool

    /// Validation error text, when validation failed.
    public let errorMessage: String?

    /// Creates a validation entry.
    ///
    /// - Parameters:
    ///   - name: Sidebar name without a file extension.
    ///   - path: Absolute path of the sidebar file represented by this entry.
    ///   - kind: Sidebar file kind raw value used on the socket wire.
    ///   - isValid: Whether the sidebar file passed validation.
    ///   - errorMessage: Validation error text, when validation failed.
    public init(name: String, path: String, kind: String, isValid: Bool, errorMessage: String?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.isValid = isValid
        self.errorMessage = errorMessage
    }
}
