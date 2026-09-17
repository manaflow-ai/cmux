import Foundation

/// The protocol every per-ecosystem adapter implements.
///
/// An adapter is responsible for one and only one thing: turning a root URL
/// (e.g. a `.xcworkspace`, a `Cargo.toml`, a `settings.gradle.kts`, or a
/// plain directory) into a ``ProjectModel`` snapshot. Watching, caching,
/// diffing, and resolution of expensive secondary information (e.g.
/// `xcodebuild -showBuildSettings`) live above this protocol.
///
/// Implementations must be `Sendable` because the project pane loads them
/// off the main actor.
public protocol ProjectAdapter: Sendable {
    /// Which ecosystem this adapter handles.
    var kind: ProjectAdapterKind { get }

    /// Lightweight check used by the registry to decide whether to try this
    /// adapter on a given root URL before paying the cost of ``load(at:)``.
    ///
    /// - Parameter url: A file URL pointing at a candidate project root.
    /// - Returns: `true` when this adapter is likely to be able to load
    ///   ``url``. Implementations should rely on cheap signals (file
    ///   extension, presence of a manifest file in the directory) and avoid
    ///   parsing.
    func canLoad(_ url: URL) -> Bool

    /// Parse the project rooted at ``url`` into an immutable
    /// ``ProjectModel`` snapshot.
    ///
    /// - Parameter url: A file URL pointing at a project root. For the Xcode
    ///   adapter this may be either a `.xcworkspace` bundle or a
    ///   `.xcodeproj` bundle, or a directory that contains one of those.
    /// - Returns: A populated ``ProjectModel``.
    /// - Throws: ``ProjectLoadError`` when the URL cannot be read, is not
    ///   supported by this adapter, or fails to parse.
    func load(at url: URL) throws -> ProjectModel
}
