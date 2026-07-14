/// An error produced while resolving one or more cmux templates.
public enum CmuxTemplateResolutionError: Error, Equatable, Sendable {
    /// Variables without an explicit value, definition value, environment
    /// value, or inline default, in first-occurrence order.
    case missingVariables([String])
}
