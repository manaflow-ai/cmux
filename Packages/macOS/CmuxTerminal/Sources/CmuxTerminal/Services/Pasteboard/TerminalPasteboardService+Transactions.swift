public import AppKit

extension TerminalPasteboardService {
    /// Reserves a concrete managed pasteboard in process-wide operation order.
    ///
    /// Named, drag, and test pasteboards are intentionally unmanaged.
    public func reservePasteboardRead(
        from pasteboard: NSPasteboard
    ) -> TerminalPasteboardReadAdmission {
        guard let lane = managedPasteboardLane(for: pasteboard) else {
            return .unmanaged
        }
        guard let lease = lane.reserveRead() else {
            return .rejected
        }
        return .reserved(lease)
    }

    /// Replaces one pasteboard through its managed lane when applicable.
    ///
    /// The return value reports admission for managed pasteboards and the
    /// immediate AppKit result for unmanaged pasteboards.
    @discardableResult
    public func replaceContents(
        of pasteboard: NSPasteboard,
        with items: [NSPasteboardItem]
    ) -> Bool {
        let contents = TerminalPasteboardItemSnapshot.snapshots(from: items)
        let mutation = TerminalPasteboardTransactionLane.Mutation(
            contents: contents,
            condition: nil,
            capturesPreviousContents: false
        )
        guard let lane = managedPasteboardLane(for: pasteboard) else {
            return unmanagedResult(for: mutation, pasteboard: pasteboard)
                .didWrite
        }
        return lane.enqueueMutation(mutation)
    }

    /// Replaces one pasteboard and waits for publication or rejection.
    ///
    /// `expectedChangeCount` is evaluated when the mutation reaches the head
    /// of the lane, not when it is enqueued. Once the mutation is admitted, the
    /// service reports its authoritative result even if the caller is cancelled.
    public func replaceContentsAndWait(
        of pasteboard: NSPasteboard,
        with items: [NSPasteboardItem],
        expectedChangeCount: Int? = nil
    ) async -> TerminalPasteboardMutationResult {
        let contents = TerminalPasteboardItemSnapshot.snapshots(from: items)
        let mutation = TerminalPasteboardTransactionLane.Mutation(
            contents: contents,
            condition: expectedChangeCount.map {
                TerminalPasteboardTransactionLane.MutationCondition
                    .changeCount($0)
            },
            capturesPreviousContents: false
        )
        guard let lane = managedPasteboardLane(for: pasteboard) else {
            return unmanagedResult(for: mutation, pasteboard: pasteboard)
        }
        guard let lease = lane.reserveMutation(mutation) else {
            return TerminalPasteboardMutationResult(
                status: .queueFull,
                publishedContents: contents
            )
        }
        defer { lease.finish() }
        return await lease.waitForAuthoritativeResult()
            ?? TerminalPasteboardMutationResult(
                status: .cancelled,
                publishedContents: contents
            )
    }

    /// Replaces one managed pasteboard while retaining exclusive ownership
    /// until the returned lease is finished.
    ///
    /// A successful result includes the bounded previous contents so the
    /// caller can conditionally restore them later.
    public func reserveMutation(
        of pasteboard: NSPasteboard,
        replacingWith items: [NSPasteboardItem]
    ) -> TerminalPasteboardMutationLease? {
        guard let lane = managedPasteboardLane(for: pasteboard) else {
            return nil
        }
        let contents = TerminalPasteboardItemSnapshot.snapshots(from: items)
        return lane.reserveMutation(.init(
            contents: contents,
            condition: nil,
            capturesPreviousContents: true
        ))
    }

    /// Restores the contents replaced by a mutation if its published payload
    /// still owns the pasteboard when this operation reaches the lane head.
    @discardableResult
    public func restoreContents(
        replacedBy result: TerminalPasteboardMutationResult,
        in pasteboard: NSPasteboard
    ) -> Bool {
        guard result.didWrite,
              let previousContents = result.previousContents,
              let publishedChangeCount = result.publishedChangeCount else {
            return false
        }
        let mutation = TerminalPasteboardTransactionLane.Mutation(
            contents: previousContents,
            condition: .changeCount(publishedChangeCount),
            capturesPreviousContents: false
        )
        guard let lane = managedPasteboardLane(for: pasteboard) else {
            return unmanagedResult(for: mutation, pasteboard: pasteboard)
                .didWrite
        }
        return lane.enqueueRestoration(mutation)
    }

    /// Writes one plain string through the managed lane when applicable.
    @discardableResult
    public func writeString(
        _ string: String,
        to pasteboard: NSPasteboard
    ) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string) else { return false }
        return replaceContents(of: pasteboard, with: [item])
    }

    private func unmanagedResult(
        for mutation: TerminalPasteboardTransactionLane.Mutation,
        pasteboard: NSPasteboard
    ) -> TerminalPasteboardMutationResult {
        let lane = TerminalPasteboardTransactionLane(
            pasteboard: pasteboard,
            maximumQueuedOperations: 1,
            maximumQueuedWriteBytes: TerminalPasteboardItemSnapshot
                .retainedByteCount(of: mutation.contents),
            previousContentsCapture: { _ in nil }
        )
        return lane.applyUnmanagedMutation(mutation)
    }
}
