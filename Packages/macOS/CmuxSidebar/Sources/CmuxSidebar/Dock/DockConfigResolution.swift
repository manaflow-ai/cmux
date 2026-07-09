public import Foundation

/// The outcome of resolving the active Dock configuration from disk.
///
/// Carries the controls to display, the file they came from (`nil` when no
/// config exists), the base directory their relative `cwd` paths resolve
/// against, and whether the source was a project-scoped `.cmux/dock.json`
/// (`isProjectSource`) rather than the global config.
public struct DockConfigResolution: Sendable {
    /// The Dock controls to display, in file order; empty when no config exists.
    public let controls: [DockControlDefinition]
    /// The config file the controls were loaded from, or `nil` when none exists.
    public let sourceURL: URL?
    /// Directory that the controls' relative working directories resolve against.
    public let baseDirectory: String
    /// `true` when the source was a project `.cmux/dock.json`, not the global config.
    public let isProjectSource: Bool

    /// Creates a resolved Dock configuration.
    public init(
        controls: [DockControlDefinition],
        sourceURL: URL?,
        baseDirectory: String,
        isProjectSource: Bool
    ) {
        self.controls = controls
        self.sourceURL = sourceURL
        self.baseDirectory = baseDirectory
        self.isProjectSource = isProjectSource
    }
}
