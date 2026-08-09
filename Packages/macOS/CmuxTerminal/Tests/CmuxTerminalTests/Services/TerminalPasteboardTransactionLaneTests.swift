import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

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
        #expect(!second.isReadyForTesting)

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
        #expect(!second.isReadyForTesting)

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
            maximumQueuedClipboardOperations: maximumQueuedOperations
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
