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

    /// Returns every writer requested by one source view for the same pending
    /// AppKit drag. NSTableView may ask once per selected row.
    func writers(for sourceView: NSView) -> [Writer] {
        writers.allObjects.filter { $0.sourceViewForDrag === sourceView }
    }

    /// Promotes all writers belonging to one native session and returns their
    /// exact cleanup identities for the terminal callback.
    func promote(writers promotedWriters: [Writer]) -> [FilePreviewNativeDragOwnership] {
        var promotedOwnerships: [FilePreviewNativeDragOwnership] = []
        for writer in promotedWriters {
            guard let tokenID = writer.provisionalToken?.id else { continue }
            if let ownership = ownershipByToken.removeValue(forKey: tokenID) {
                promotedOwnerships.append(ownership)
            } else if let ownership = writer.nativeDragOwnership() {
                promotedOwnerships.append(ownership)
            }
            tokenOwnership.remove(id: tokenID)
        }
        for writer in promotedWriters {
            writers.remove(writer)
        }
        return promotedOwnerships
    }

    /// Finishes every pending writer except the writers AppKit is promoting.
    func finishPending(excluding preservedWriter: Writer? = nil) {
        finishPending(preserving: preservedWriter.map { [$0] } ?? [])
    }

    /// Revokes pending registrations that do not belong to the promoted
    /// native session. Every preserved writer stays registered until endedAt
    /// so multi-row pasteboards resolve their first item correctly.
    func finishPending(preserving preservedWriters: [Writer]) {
        let preservedTokenIDs = Set(preservedWriters.compactMap { $0.provisionalToken?.id })
        let pendingWriters = writers.allObjects
        for writer in pendingWriters where !preservedWriters.contains(where: { $0 === writer }) {
            if let tokenID = writer.provisionalToken?.id {
                ownershipByToken[tokenID]?.revokeRouting()
                ownershipByToken.removeValue(forKey: tokenID)
                tokenOwnership.remove(id: tokenID)
            }
            writer.releaseSourceGraph()
        }
        let remainingOwnership = ownershipByToken.filter { !preservedTokenIDs.contains($0.key) }
        for (tokenID, ownership) in remainingOwnership {
            ownership.revokeRouting()
            ownershipByToken.removeValue(forKey: tokenID)
            tokenOwnership.remove(id: tokenID)
        }
        writers.removeAllObjects()
        for writer in preservedWriters {
            writers.add(writer)
        }
    }

    private func writerDidDeallocate(tokenID: UUID) {
        guard let ownership = ownershipByToken.removeValue(forKey: tokenID) else { return }
        ownership.revokeRouting()
        onWriterDeallocated(tokenID)
    }
}
