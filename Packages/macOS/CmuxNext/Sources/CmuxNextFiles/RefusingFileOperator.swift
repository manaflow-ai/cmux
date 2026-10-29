public import Foundation

/// A ``FileOperating`` that changes nothing: every operation fails with `refusal`. For a view that outlived
/// the service that changes its files (the App's null effects).
public struct RefusingFileOperator: FileOperating {
    private let refusal: FileBrowserError

    /// Refuses every operation with `refusal`.
    public init(refusal: FileBrowserError) { self.refusal = refusal }

    public func rename(_ url: URL, to name: String) async throws -> URL { throw refusal }
    public func newFolder(in folder: URL, named name: String) async throws -> URL { throw refusal }
    public func newFile(in folder: URL, named name: String, contents: Data) async throws -> URL { throw refusal }
    public func duplicate(_ urls: [URL]) async throws -> [URL] { throw refusal }
    public func trash(_ urls: [URL]) async throws -> [TrashedItem] { throw refusal }
    public func putBack(_ items: [TrashedItem]) async throws -> [URL] { throw refusal }
    public func move(_ pairs: [(from: URL, to: URL)]) async throws { throw refusal }
    public func transfer(_ sources: [URL], to folder: URL, mode: TransferMode,
                         resolve: @escaping @Sendable (FileConflict) async -> ConflictAnswer)
        -> AsyncThrowingStream<TransferEvent, any Error> {
        let refusal = refusal
        return AsyncThrowingStream { $0.finish(throwing: refusal) }
    }
    public func makeLinks(_ urls: [URL], kind: LinkKind) async throws -> [URL] { throw refusal }
    public func deleteImmediately(_ urls: [URL]) async throws { throw refusal }
    public func compress(_ urls: [URL], archiveName: String) async throws -> URL { throw refusal }
    public func expand(_ archive: URL) async throws -> URL { throw refusal }
}
