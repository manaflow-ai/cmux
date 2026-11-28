public import Foundation

/// Capability to open a file for the user.
///
/// Consumer domains (terminal cmd-click routing, settings-file shortcuts,
/// sidebar config openers) depend on this seam instead of the concrete
/// ``PreferredEditorService`` so they can be tested with a recording fake
/// and never name the launch mechanism.
public protocol FileOpening: Sendable {
    /// Opens `url` for the user, honoring their preferred-editor setting.
    @MainActor func open(_ url: URL)
}
