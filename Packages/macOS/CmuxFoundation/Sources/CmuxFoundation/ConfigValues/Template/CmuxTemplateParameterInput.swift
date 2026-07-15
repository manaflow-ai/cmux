/// One editable value requested by a cmux template launch surface.
public struct CmuxTemplateParameterInput: Equatable, Sendable {
    /// The placeholder name shown to the user.
    public let name: String

    /// The value supplied by definition, environment, or inline-default
    /// precedence before the user edits it.
    public let suggestedValue: String?

    /// Creates an editable template parameter description.
    public init(name: String, suggestedValue: String?) {
        self.name = name
        self.suggestedValue = suggestedValue
    }
}
