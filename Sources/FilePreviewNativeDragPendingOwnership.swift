import AppKit

/// Owns provisional file-preview writers until AppKit promotes or abandons them.
@MainActor
final class FilePreviewNativeDragPendingOwnership {
    typealias Writer = FilePreviewDragPasteboardWriter
    typealias Token = ProvisionalDragWriterOwnership.Token

    private var ownershipByToken: [UUID: FilePreviewNativeDragOwnership] = [:]
    private let writers = NSHashTable<Writer>.weakObjects()
    private let onWriterDeallocated: @MainActor (UUID) -> Void
    private lazy var tokenOwnership = ProvisionalDragWriterOwnership { [weak self] tokenID in
        self?.writerDidDeallocate(tokenID: tokenID)
    }

    init(onWriterDeallocated: @escaping @MainActor (UUID) -> Void) {
        self.onWriterDeallocated = onWriterDeallocated
    }

    /// Creates the token passed to a writer before its initializer runs.
    func makeToken() -> Token {
        tokenOwnership.makeToken()
    }

    /// Records a writer and captures its exact cleanup identity.
    func register(_ writer: Writer) -> FilePreviewNativeDragOwnership? {
        writers.add(writer)
        guard let tokenID = writer.provisionalToken?.id,
              let ownership = writer.nativeDragOwnership() else {
            return nil
        }
        ownershipByToken[tokenID] = ownership
        return ownership
    }

    /// Removes a promoted writer from the provisional set.
    func remove(tokenID: UUID) {
        tokenOwnership.remove(id: tokenID)
        ownershipByToken.removeValue(forKey: tokenID)
    }

    /// Finishes every pending writer except the one AppKit is promoting.
    func finishPending(excluding preservedWriter: Writer? = nil) {
        let preservedTokenID = preservedWriter?.provisionalToken?.id
        let pendingWriters = writers.allObjects
        for writer in pendingWriters where writer !== preservedWriter {
            if let tokenID = writer.provisionalToken?.id {
                ownershipByToken[tokenID]?.finish(from: NSPasteboard(name: .drag))
                ownershipByToken.removeValue(forKey: tokenID)
                tokenOwnership.remove(id: tokenID)
            }
            writer.releaseSourceGraph()
        }
        let remainingOwnership = ownershipByToken.filter { $0.key != preservedTokenID }
        for (tokenID, ownership) in remainingOwnership {
            ownership.finish(from: NSPasteboard(name: .drag))
            ownershipByToken.removeValue(forKey: tokenID)
            tokenOwnership.remove(id: tokenID)
        }
        writers.removeAllObjects()
        if let preservedWriter {
            writers.add(preservedWriter)
        }
    }

    private func writerDidDeallocate(tokenID: UUID) {
        guard let ownership = ownershipByToken.removeValue(forKey: tokenID) else { return }
        ownership.finish(from: NSPasteboard(name: .drag))
        onWriterDeallocated(tokenID)
    }
}
