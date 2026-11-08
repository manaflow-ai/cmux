import AppKit

/// Applies one pasteboard mutation and recovers the contents it displaced when
/// AppKit rejects a write after the pasteboard has already been cleared.
final class TerminalPasteboardMutationApplier {
    typealias PasteboardWrite = ([NSPasteboardItem]) -> Bool

    private struct ApplicationOutcome {
        let result: TerminalPasteboardMutationResult
        let recoveredContents: TerminalPasteboardContentsSnapshot?
    }

    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private let pasteboardWrite: PasteboardWrite

    init(
        pasteboard: NSPasteboard,
        pasteboardWrite: PasteboardWrite? = nil
    ) {
        self.pasteboard = pasteboard
        self.pasteboardWrite = pasteboardWrite ?? { [pasteboard] items in
            pasteboard.writeObjects(items)
        }
    }

    func apply(
        _ mutation: TerminalPasteboardTransactionLane.Mutation,
        previousContents snapshot: TerminalPasteboardContentsSnapshot?
    ) -> TerminalPasteboardMutationResult {
        applyWithRecovery(
            mutation,
            previousContents: snapshot
        ).result
    }

    /// Restores a mutation whose lease was finished before publication became
    /// observable.
    func restoreAbandonedMutation(
        _ result: TerminalPasteboardMutationResult
    ) {
        guard result.didWrite,
              let previousContents = result.previousContents,
              let publishedChangeCount = result.publishedChangeCount else {
            return
        }
        let publishedContents = TerminalPasteboardContentsSnapshot(
            changeCount: publishedChangeCount,
            contents: result.publishedContents
        )
        let restoration = applyWithRecovery(
            .init(
                contents: previousContents,
                condition: .changeCount(publishedChangeCount),
                capturesPreviousContents: true
            ),
            previousContents: publishedContents
        )
        guard restoration.result.status == .writeFailed,
              let recoveredContents = restoration.recoveredContents else {
            return
        }
        _ = applyWithRecovery(
            .init(
                contents: previousContents,
                condition: .changeCount(recoveredContents.changeCount),
                capturesPreviousContents: true
            ),
            previousContents: recoveredContents
        )
    }

    private func applyWithRecovery(
        _ mutation: TerminalPasteboardTransactionLane.Mutation,
        previousContents snapshot: TerminalPasteboardContentsSnapshot?
    ) -> ApplicationOutcome {
        guard let items = makePasteboardItems(from: mutation.contents) else {
            return failure(
                status: .writeFailed,
                publishedContents: mutation.contents
            )
        }

        switch mutation.condition {
        case .changeCount(let expectedChangeCount):
            guard pasteboard.changeCount == expectedChangeCount else {
                return failure(
                    status: .conditionNotMet,
                    publishedContents: mutation.contents
                )
            }
        case nil:
            break
        }

        let previousContents: [TerminalPasteboardItemSnapshot]?
        if mutation.capturesPreviousContents {
            guard let snapshot else {
                return failure(
                    status: .captureLimitExceeded,
                    publishedContents: mutation.contents
                )
            }
            guard pasteboard.changeCount == snapshot.changeCount else {
                return failure(
                    status: .conditionNotMet,
                    publishedContents: mutation.contents
                )
            }
            previousContents = snapshot.contents
        } else {
            previousContents = nil
        }

        let previousItems: [NSPasteboardItem]?
        if let previousContents {
            guard let reconstructed = makePasteboardItems(
                from: previousContents
            ) else {
                return failure(
                    status: .captureLimitExceeded,
                    publishedContents: mutation.contents
                )
            }
            previousItems = reconstructed
        } else {
            previousItems = nil
        }

        if let snapshot,
           pasteboard.changeCount != snapshot.changeCount {
            return failure(
                status: .conditionNotMet,
                publishedContents: mutation.contents
            )
        }

        pasteboard.clearContents()
        let wrote = mutation.contents.isEmpty || pasteboardWrite(items)
        var recoveredContents: TerminalPasteboardContentsSnapshot?
        if !wrote, let previousItems, let previousContents {
            pasteboard.clearContents()
            let recovered = previousItems.isEmpty
                || pasteboardWrite(previousItems)
            if recovered {
                recoveredContents = TerminalPasteboardContentsSnapshot(
                    changeCount: pasteboard.changeCount,
                    contents: previousContents
                )
            }
        }
        return ApplicationOutcome(
            result: TerminalPasteboardMutationResult(
                status: wrote ? .written : .writeFailed,
                previousContents: previousContents,
                publishedContents: mutation.contents,
                publishedChangeCount: wrote ? pasteboard.changeCount : nil
            ),
            recoveredContents: recoveredContents
        )
    }

    private func failure(
        status: TerminalPasteboardMutationResult.Status,
        publishedContents: [TerminalPasteboardItemSnapshot]
    ) -> ApplicationOutcome {
        ApplicationOutcome(
            result: TerminalPasteboardMutationResult(
                status: status,
                publishedContents: publishedContents
            ),
            recoveredContents: nil
        )
    }

    private func makePasteboardItems(
        from contents: [TerminalPasteboardItemSnapshot]
    ) -> [NSPasteboardItem]? {
        let items = contents.compactMap { $0.makePasteboardItem() }
        return items.count == contents.count ? items : nil
    }
}
