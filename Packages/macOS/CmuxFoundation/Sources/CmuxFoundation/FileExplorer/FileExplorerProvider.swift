/// Source of directory listings for the file explorer.
///
/// The seam between the file-explorer store and a concrete backend (local
/// filesystem or a remote SSH host). Conformers own their own availability and
/// home-path state; the store reads listings through ``listDirectory(path:showHidden:)``.
public protocol FileExplorerProvider: AnyObject {
    /// Lists the children of `path`, optionally including dotfiles.
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry]
    /// Absolute home directory for this provider.
    var homePath: String { get }
    /// Whether the provider can currently serve listings.
    var isAvailable: Bool { get }
}
