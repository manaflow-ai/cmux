import AppKit

/// Owns provisional file-preview writers until AppKit promotes or abandons them.
@MainActor
final class FilePreviewNativeDragPendingOwnership {
    typealias Writer = FilePreviewDragPasteboardWriter
    typealias Token = ProvisionalDragWriterOwnership.Token

    private final class WeakWriter {
        weak var value: Writer?

        init(_ value: Writer) {
            self.value = value
        }
    }

    private var ownershipByToken: [UUID: FilePreviewNativeDragOwnership] = [:]
    // NSHashTable does not preserve request order. AppKit writes multi-row
    // items in the same order it asks for them, so retain that order weakly to
    // choose the first item deterministically while never retaining writers.
    private var orderedWriters: [WeakWriter] = []
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

    /// Records a writer without creating process-local routing state.
    ///
    /// AppKit may ask for writers and then abandon the gesture before a native
    /// session exists. Registration is therefore deferred until AppKit
    /// consumes the writer or the owner promotes it.
    func register(_ writer: Writer) {
        pruneWriterOrder()
        orderedWriters.removeAll { $0.value === writer }
        orderedWriters.append(WeakWriter(writer))
        writer.setNativeDragOwnershipHandler { [weak self] writer, ownership in
            guard let self,
                  let tokenID = writer.provisionalToken?.id else { return }
            self.ownershipByToken[tokenID] = ownership
        }
    }

    /// Removes a promoted writer from the provisional set.
    func remove(tokenID: UUID) {
        tokenOwnership.remove(id: tokenID)
        ownershipByToken.removeValue(forKey: tokenID)
    }

    /// Returns every writer requested by one source view for the same pending
    /// AppKit drag. NSTableView may ask once per selected row.
    func writers(for sourceView: NSView) -> [Writer] {
        pruneWriterOrder()
        return orderedWriters.compactMap { $0.value }
            .filter { $0.sourceViewForDrag === sourceView }
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
                ownershipByToken.removeValue(forKey: tokenID)
            }
            writer.clearNativeDragOwnershipHandler()
            tokenOwnership.remove(id: tokenID)
        }
        orderedWriters.removeAll { box in
            guard let writer = box.value else { return true }
            return promotedWriters.contains { $0 === writer }
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
        pruneWriterOrder()
        let pendingWriters = orderedWriters.compactMap { $0.value }
        for writer in pendingWriters where !preservedWriters.contains(where: { $0 === writer }) {
            if let tokenID = writer.provisionalToken?.id {
                ownershipByToken[tokenID]?.revokeRouting()
                ownershipByToken.removeValue(forKey: tokenID)
                tokenOwnership.remove(id: tokenID)
            }
            writer.clearNativeDragOwnershipHandler()
            writer.releaseSourceGraph()
        }
        let remainingOwnership = ownershipByToken.filter { !preservedTokenIDs.contains($0.key) }
        for (tokenID, ownership) in remainingOwnership {
            ownership.revokeRouting()
            ownershipByToken.removeValue(forKey: tokenID)
            tokenOwnership.remove(id: tokenID)
        }
        orderedWriters = preservedWriters.map(WeakWriter.init)
    }

    private func writerDidDeallocate(tokenID: UUID) {
        if let ownership = ownershipByToken.removeValue(forKey: tokenID) {
            ownership.revokeRouting()
        }
        onWriterDeallocated(tokenID)
    }

    private func pruneWriterOrder() {
        orderedWriters.removeAll { $0.value == nil }
    }
}
