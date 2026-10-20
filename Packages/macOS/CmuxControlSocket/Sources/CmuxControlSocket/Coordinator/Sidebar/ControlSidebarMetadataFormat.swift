internal import Foundation

/// The render format of a sidebar status/metadata entry (the typed twin of the
/// app's `SidebarMetadataFormat`; raw values match so the conformance can
/// rebuild the app enum losslessly).
public enum ControlSidebarMetadataFormat: String, Sendable, Equatable {
    /// Plain text.
    case plain
    /// Markdown.
    case markdown
}
