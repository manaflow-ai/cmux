public import Foundation

/// Capability to open a file with the operating system's default handler.
///
/// ``PreferredEditorService`` falls back to this when no editor command is
/// configured or the configured command fails; tests inject a recording
/// fake, the app injects ``NSWorkspaceFileOpener``.
public protocol SystemFileOpening: Sendable {
    /// Opens `url` with the system default application.
    @MainActor func openWithSystemDefault(_ url: URL)
}
