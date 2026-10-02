import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

private final class TransactionLanePasteboardDataProvider:
    NSObject,
    NSPasteboardItemDataProvider
{
    private let replacement: String?
    private let lock = NSLock()
    private var _resolvedOnMainThread: Bool?

    init(replacement: String? = nil) {
        self.replacement = replacement
    }

    var resolvedOnMainThread: Bool? {
        lock.withLock { _resolvedOnMainThread }
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.withLock {
            _resolvedOnMainThread = Thread.isMainThread
        }
        _ = item.setString("user clipboard", forType: type)

        guard let replacement, let pasteboard else { return }
        let replacementItem = NSPasteboardItem()
        _ = replacementItem.setString(replacement, forType: .string)
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([replacementItem])
    }
}

private func captureTransactionLanePasteboardContents(
    _ request: TerminalPasteboardContentsCaptureRequest
) -> TerminalPasteboardContentsSnapshot? {
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name(request.pasteboardName)
    )
    guard pasteboard.changeCount == request.changeCount,
          let contents = TerminalPasteboardItemSnapshot.captureContents(
            of: pasteboard,
            maximumByteCount: request.maximumByteCount
          ),
          pasteboard.changeCount == request.changeCount else {
        return nil
    }
    return TerminalPasteboardContentsSnapshot(
        changeCount: request.changeCount,
        contents: contents
    )
}

@MainActor
@Suite("Terminal pasteboard transaction lane", .serialized)
struct TerminalPasteboardTransactionLaneTests {
    @Test("a write between two reads preserves process admission order")
    func writeBetweenReadsPreservesAdmissionOrder() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("old", forType: .string)

        let first = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        let firstReady = await first.waitUntilReady()
        #expect(firstReady)

        fixture.service.writeString(
            "new",
            to: GHOSTTY_CLIPBOARD_STANDARD
        )
        let second = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )

        #expect(fixture.standard.string(forType: .string) == "old")
        #expect(!second.isReady)

        first.finish()

        #expect(fixture.standard.string(forType: .string) == "new")
        let secondReady = await second.waitUntilReady()
        #expect(secondReady)
        second.finish()
    }

    @Test("the bounded lane coalesces adjacent clipboard writes")
    func boundedLaneCoalescesAdjacentWrites() async throws {
        let fixture = makeFixture(maximumQueuedOperations: 2)
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("old", forType: .string)

        let read = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        let readReady = await read.waitUntilReady()
        #expect(readReady)

        fixture.service.writeString(
            "first",
            to: GHOSTTY_CLIPBOARD_STANDARD
        )
        #expect(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            ) == nil
        )
        fixture.service.writeString(
            "latest",
            to: GHOSTTY_CLIPBOARD_STANDARD
        )

        #expect(fixture.standard.string(forType: .string) == "old")
        read.finish()
        #expect(fixture.standard.string(forType: .string) == "latest")
    }

    @Test("rejected coalescing never publishes a superseded write")
    func rejectedCoalescingDropsSupersededWrite() async throws {
        let pasteboard = NSPasteboard(
            name: .init("cmux-transaction-coalescing-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        pasteboard.clearContents()
        #expect(pasteboard.setString("original", forType: .string))

        let retainedItem = NSPasteboardItem()
        #expect(retainedItem.setString("retained", forType: .string))
        let supersededItem = NSPasteboardItem()
        #expect(supersededItem.setString("a", forType: .string))
        let latestItem = NSPasteboardItem()
        #expect(latestItem.setString("latest", forType: .string))
        let retainedContents = TerminalPasteboardItemSnapshot.snapshots(
            from: [retainedItem]
        )
        let supersededContents = TerminalPasteboardItemSnapshot.snapshots(
            from: [supersededItem]
        )
        let latestContents = TerminalPasteboardItemSnapshot.snapshots(
            from: [latestItem]
        )
        let maximumQueuedWriteBytes =
            TerminalPasteboardItemSnapshot.retainedByteCount(
                of: retainedContents + supersededContents
            )
        #expect(
            TerminalPasteboardItemSnapshot.retainedByteCount(
                of: retainedContents + latestContents
            ) > maximumQueuedWriteBytes
        )

        let lane = TerminalPasteboardTransactionLane(
            pasteboard: pasteboard,
            maximumQueuedWriteBytes: maximumQueuedWriteBytes,
            previousContentsCapture: { _ in nil }
        )
        let read = try #require(lane.reserveRead())
        #expect(await read.waitUntilReady())
        let retainedLease = try #require(lane.reserveMutation(.init(
            contents: retainedContents,
            condition: nil,
            capturesPreviousContents: false
        )))
        #expect(lane.enqueueMutation(.init(
            contents: supersededContents,
            condition: nil,
            capturesPreviousContents: false
        )))
        #expect(!lane.enqueueMutation(.init(
            contents: latestContents,
            condition: nil,
            capturesPreviousContents: false
        )))

        read.finish()
        #expect(await retainedLease.waitUntilApplied()?.status == .written)
        retainedLease.finish()
        #expect(pasteboard.string(forType: .string) == "retained")
    }

    @Test("generic image and file URL writes stay ordered between reads")
    func genericMutationBetweenReadsPreservesAdmissionOrder() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("old", forType: .string)

        let first = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        #expect(await first.waitUntilReady())

        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-lane-image.png")
        let item = NSPasteboardItem()
        #expect(item.setData(pngData, forType: .png))
        #expect(item.setString(fileURL.absoluteString, forType: .fileURL))
        #expect(
            fixture.service.replaceContents(
                of: fixture.standard,
                with: [item]
            )
        )
        let second = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )

        #expect(fixture.standard.string(forType: .string) == "old")
        #expect(!second.isReady)

        first.finish()

        #expect(fixture.standard.data(forType: .png) == pngData)
        #expect(
            fixture.standard.string(forType: .fileURL)
                == fileURL.absoluteString
        )
        #expect(await second.waitUntilReady())
        second.finish()
    }

    @Test("clipboard restoration has one bounded slot when the lane is full")
    func restorationIsAdmittedWhenOrdinaryLaneIsFull() async throws {
        let fixture = makeFixture(maximumQueuedOperations: 2)
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("user clipboard", forType: .string)

        let temporaryItem = NSPasteboardItem()
        #expect(temporaryItem.setString("temporary", forType: .string))
        let mutationLease = try #require(
            fixture.service.reserveMutation(
                of: fixture.standard,
                replacingWith: [temporaryItem]
            )
        )
        let mutationResult = try #require(
            await mutationLease.waitUntilApplied()
        )
        mutationLease.finish()

        let activeRead = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        #expect(await activeRead.waitUntilReady())
        let queuedRead = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        #expect(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            ) == nil
        )

        #expect(
            fixture.service.restoreContents(
                replacedBy: mutationResult,
                in: fixture.standard
            )
        )
        #expect(
            fixture.standard.string(forType: .string) == "temporary"
        )

        activeRead.finish()
        #expect(await queuedRead.waitUntilReady())
        #expect(
            fixture.standard.string(forType: .string) == "temporary"
        )
        queuedRead.finish()

        #expect(
            fixture.standard.string(forType: .string) == "user clipboard"
        )
    }

    @Test("an applied mutation keeps its rollback snapshot after repeated finish")
    func appliedMutationResultSurvivesRepeatedFinish() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("user clipboard", forType: .string)

        let temporaryItem = NSPasteboardItem()
        #expect(temporaryItem.setString("temporary", forType: .string))
        let lease = try #require(
            fixture.service.reserveMutation(
                of: fixture.standard,
                replacingWith: [temporaryItem]
            )
        )
        #expect(await lease.waitUntilApplied() != nil)

        let cancellationHandlerResult = try #require(lease.finish())
        let ownerResult = try #require(lease.finish())
        #expect(cancellationHandlerResult.status == .written)
        #expect(ownerResult.status == .written)
        #expect(
            ownerResult.previousContents
                == cancellationHandlerResult.previousContents
        )
        #expect(
            fixture.service.restoreContents(
                replacedBy: ownerResult,
                in: fixture.standard
            )
        )
        #expect(
            fixture.standard.string(forType: .string) == "user clipboard"
        )
    }

    @Test("finish before apply keeps rollback ownership in the lane")
    func finishBeforeAppliedSignalKeepsRollbackOwnershipInLane() {
        let previousContents = [TerminalPasteboardItemSnapshot(
            representations: [.init(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                data: Data("user clipboard".utf8)
            )]
        )]
        let result = TerminalPasteboardMutationResult(
            status: .written,
            previousContents: previousContents,
            publishedContents: [],
            publishedChangeCount: 42
        )
        let lease = TerminalPasteboardMutationLease(id: 1) {}

        #expect(lease.finish() == nil)
        let disposition = lease.signalApplied(result)

        #expect(disposition == .laneMustRestore)
        #expect(lease.finish()?.previousContents == previousContents)
    }

    @Test("an abandoned mutation retries restoration after a write failure")
    func abandonedMutationRetriesRestorationAfterWriteFailure() async throws {
        let pasteboard = NSPasteboard(
            name: .init("cmux-abandoned-mutation-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        pasteboard.clearContents()
        #expect(pasteboard.setString("user clipboard", forType: .string))

        var mutationLease: TerminalPasteboardMutationLease?
        var writeAttempt = 0
        let lane = TerminalPasteboardTransactionLane(
            pasteboard: pasteboard,
            previousContentsCapture: { request in
                captureTransactionLanePasteboardContents(request)
            },
            pasteboardWrite: { items in
                writeAttempt += 1
                if writeAttempt == 2 {
                    return false
                }
                let wrote = pasteboard.writeObjects(items)
                if writeAttempt == 1 {
                    mutationLease?.finish()
                }
                return wrote
            }
        )
        let activeRead = try #require(lane.reserveRead())
        #expect(await activeRead.waitUntilReady())

        let temporaryItem = NSPasteboardItem()
        #expect(temporaryItem.setString("temporary", forType: .string))
        mutationLease = try #require(lane.reserveMutation(.init(
            contents: TerminalPasteboardItemSnapshot.snapshots(
                from: [temporaryItem]
            ),
            condition: nil,
            capturesPreviousContents: true
        )))
        let queuedRead = try #require(lane.reserveRead())

        activeRead.finish()
        #expect(await queuedRead.waitUntilReady())
        queuedRead.finish()

        #expect(pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test("failed item reconstruction preserves the existing clipboard")
    func failedItemReconstructionPreservesExistingClipboard() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("user clipboard", forType: .string)
        let lane = TerminalPasteboardTransactionLane(
            pasteboard: fixture.standard,
            previousContentsCapture: { _ in nil }
        )

        let result = lane.applyUnmanagedMutation(.init(
            contents: [TerminalPasteboardItemSnapshot(representations: [])],
            condition: nil,
            capturesPreviousContents: false
        ))

        #expect(result.status == .writeFailed)
        #expect(
            fixture.standard.string(forType: .string) == "user clipboard"
        )
    }

    @Test("rollback capture resolves lazy providers away from the main thread")
    func rollbackCaptureResolvesLazyProvidersOffMainThread() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let provider = TransactionLanePasteboardDataProvider()
        let lazyItem = NSPasteboardItem()
        lazyItem.setDataProvider(provider, forTypes: [.string])
        fixture.standard.clearContents()
        #expect(fixture.standard.writeObjects([lazyItem]))

        let temporaryItem = NSPasteboardItem()
        #expect(temporaryItem.setString("temporary", forType: .string))
        let lease = try #require(
            fixture.service.reserveMutation(
                of: fixture.standard,
                replacingWith: [temporaryItem]
            )
        )
        defer { lease.finish() }
        #expect(await lease.waitUntilApplied()?.status == .written)
        #expect(provider.resolvedOnMainThread == false)
        withExtendedLifetime(provider) {}
    }

    @Test("external clipboard changes during rollback capture are preserved")
    func externalClipboardChangeDuringCaptureIsPreserved() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let provider = TransactionLanePasteboardDataProvider(
            replacement: "external clipboard"
        )
        let lazyItem = NSPasteboardItem()
        lazyItem.setDataProvider(provider, forTypes: [.string])
        fixture.standard.clearContents()
        #expect(fixture.standard.writeObjects([lazyItem]))

        let temporaryItem = NSPasteboardItem()
        #expect(temporaryItem.setString("temporary", forType: .string))
        let lease = try #require(
            fixture.service.reserveMutation(
                of: fixture.standard,
                replacingWith: [temporaryItem]
            )
        )
        defer { lease.finish() }
        // The isolated capture rejects the now-stale snapshot, which the lane
        // reports as a capture failure without touching the external contents.
        #expect(
            await lease.waitUntilApplied()?.status == .captureLimitExceeded
        )
        #expect(
            fixture.standard.string(forType: .string)
                == "external clipboard"
        )
        withExtendedLifetime(provider) {}
    }

    private func makeFixture(
        maximumQueuedOperations: Int = 8
    ) -> (
        service: TerminalPasteboardService,
        standard: NSPasteboard,
        selection: NSPasteboard,
        cleanup: @MainActor () -> Void
    ) {
        let standard = NSPasteboard(
            name: .init("cmux-transaction-standard-\(UUID().uuidString)")
        )
        let selection = NSPasteboard(
            name: .init("cmux-transaction-selection-\(UUID().uuidString)")
        )
        let service = TerminalPasteboardService(
            standardPasteboard: standard,
            selectionPasteboard: selection,
            maximumQueuedClipboardOperations: maximumQueuedOperations,
            previousContentsCapture: { request in
                captureTransactionLanePasteboardContents(request)
            }
        )
        return (
            service,
            standard,
            selection,
            {
                standard.clearContents()
                selection.clearContents()
                standard.releaseGlobally()
                selection.releaseGlobally()
            }
        )
    }
}
