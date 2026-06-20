public import Foundation

/// Resolves the directory libghostty should read its bundled resources from.
///
/// A tagged cmux build may inherit `GHOSTTY_RESOURCES_DIR` from another
/// running cmux instance whose bundle has since moved or been pruned, so the
/// resolver prefers this app's own bundled `ghostty` resources (with a
/// `themes` subdirectory present) over any inherited value, then falls back in
/// order to the inherited value, a system Ghostty.app install, and finally an
/// incomplete bundled copy.
///
/// Resolution is pure only up to the file system: every candidate is probed
/// for existence, so the file-existence capability and the system Ghostty.app
/// resources path are injected at init. Production uses the real file system
/// and the standard install path; tests inject a scoped probe and a temporary
/// path. The probe is a `@Sendable` closure (not a stored `FileManager`, which
/// is non-`Sendable`), mirroring ``TerminalPathResolver``'s injected
/// `fileExists` seam.
public struct GhosttyResourcesDirectoryResolver: Sendable {
    private let ghosttyAppResources: String
    private let fileExists: @Sendable (String) -> Bool

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - ghosttyAppResources: Path to a system Ghostty.app's bundled
    ///     resources, used as a fallback when neither this app's bundle nor the
    ///     inherited value resolves. Defaults to the standard install location.
    ///   - fileExists: The file-existence capability used to probe candidate
    ///     paths; defaults to the real file system.
    public init(
        ghosttyAppResources: String = "/Applications/Ghostty.app/Contents/Resources/ghostty",
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.ghosttyAppResources = ghosttyAppResources
        self.fileExists = fileExists
    }

    /// Resolves the resources directory from the inherited value and this
    /// app's bundle.
    ///
    /// - Parameters:
    ///   - currentValue: The inherited `GHOSTTY_RESOURCES_DIR` value, if any.
    ///   - bundleResourceURL: This app's `Bundle.main.resourceURL`, if any.
    /// - Returns: The first existing candidate in preference order, or `nil`
    ///   when no candidate exists.
    public func resolve(
        currentValue: String?,
        bundleResourceURL: URL?
    ) -> String? {
        let bundledGhosttyURL = bundleResourceURL?.appendingPathComponent("ghostty")
        // Tagged cmux builds may inherit GHOSTTY_RESOURCES_DIR from another running
        // cmux instance. Prefer this app's bundled resources when they are present.
        if let bundledGhosttyURL,
           fileExists(bundledGhosttyURL.path),
           fileExists(bundledGhosttyURL.appendingPathComponent("themes").path) {
            return bundledGhosttyURL.path
        }

        if let currentValue = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentValue.isEmpty,
           fileExists(currentValue) {
            return currentValue
        }

        if fileExists(ghosttyAppResources) {
            return ghosttyAppResources
        }

        if let bundledGhosttyURL,
           fileExists(bundledGhosttyURL.path) {
            return bundledGhosttyURL.path
        }

        return nil
    }
}
