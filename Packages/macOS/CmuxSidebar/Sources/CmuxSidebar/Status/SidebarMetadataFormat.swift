/// How a sidebar status entry's value text is rendered.
///
/// Raw values are a control-socket wire format; frozen.
public enum SidebarMetadataFormat: String, Sendable, Equatable {
    /// Plain text.
    case plain
    /// Markdown-rendered text.
    case markdown
}
