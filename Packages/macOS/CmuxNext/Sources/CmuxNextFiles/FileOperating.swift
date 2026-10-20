public import Foundation

/// The file changes Files makes: the seam the model writes through, so model
/// tests run against a temp folder or a fake.
public protocol FileOperating: Sendable {
    /// Renames `url` to `name` in its folder and returns the new URL.
    /// - Throws: ``FileBrowserError/invalidName(_:)``, ``FileBrowserError/exists(_:)``, ``FileBrowserError/failed(_:)``.
    func rename(_ url: URL, to name: String) async throws -> URL

    /// Makes a folder in `folder` under the first free name from `name` ("untitled folder 2").
    func newFolder(in folder: URL, named name: String) async throws -> URL

    /// Copies each item beside itself as "name copy" and returns the copies in order.
    func duplicate(_ urls: [URL]) async throws -> [URL]

    /// Moves each item to the Trash and returns where each went.
    func trash(_ urls: [URL]) async throws -> [TrashedItem]

    /// Puts trashed items back where they were (Put Back, Undo of Move to Trash).
    /// An item whose old place is taken comes back under a numbered name.
    /// Returns where each item now is.
    func putBack(_ items: [TrashedItem]) async throws -> [URL]

    /// Moves items to exact destinations (Undo of a move or rename).
    func move(_ pairs: [(from: URL, to: URL)]) async throws

    /// Copies or moves `sources` into `folder`, asking `resolve` about each
    /// taken name. Cancelling the iterating task stops between (and inside) items.
    func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                  resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer)
        -> AsyncThrowingStream<TransferEvent, any Error>
}
