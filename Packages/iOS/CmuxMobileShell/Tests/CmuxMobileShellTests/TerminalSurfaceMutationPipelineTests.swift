import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Suite("Terminal surface mutation pipeline")
struct TerminalSurfaceMutationPipelineTests {
    @Test("queued output stays ahead of a local scroll")
    func outputBeforeScroll() {
        var queue = TerminalOutputDeliveryQueue()
        let output = TerminalOutputDelivery(bytes: Data("before".utf8), replaceable: false)
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: -4, col: 1, row: 2)],
            receipt: TerminalSurfaceMutationReceipt()
        )

        #expect(queue.enqueue(output) == output)
        #expect(queue.enqueue(scroll) == nil)
        #expect(queue.completeInFlight() == scroll)
    }

    @Test("output submitted after a local scroll stays behind it")
    func outputAfterScroll() {
        var queue = TerminalOutputDeliveryQueue()
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: 5, col: 3, row: 4)],
            receipt: TerminalSurfaceMutationReceipt()
        )
        let output = TerminalOutputDelivery(bytes: Data("after".utf8), replaceable: false)

        #expect(queue.enqueue(scroll) == scroll)
        #expect(queue.enqueue(output) == nil)
        #expect(queue.completeInFlight() == output)
    }

    @Test("opposite local scroll runs retain causal order")
    func oppositeScrollRunsRetainOrder() throws {
        var queue = TerminalOutputDeliveryQueue()
        let up = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: -8, col: 2, row: 3)],
            receipt: TerminalSurfaceMutationReceipt()
        )
        let down = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: 6, col: 4, row: 5)],
            receipt: TerminalSurfaceMutationReceipt()
        )

        #expect(queue.enqueue(up) == up)
        #expect(queue.enqueue(down) == nil)
        guard case .localScroll(let firstRuns) = try #require(queue.currentInFlight).mutation else {
            Issue.record("expected first local scroll mutation")
            return
        }
        #expect(firstRuns.map(\.lines) == [-8])

        let promoted = queue.completeInFlight()
        let second = try #require(promoted)
        guard case .localScroll(let secondRuns) = second.mutation else {
            Issue.record("expected second local scroll mutation")
            return
        }
        #expect(secondRuns.map(\.lines) == [6])
    }

    @Test("viewport output replacement cannot cross a scroll or barrier")
    func replacementStopsAtMutationBoundaries() {
        var queue = TerminalOutputDeliveryQueue()
        let head = TerminalOutputDelivery(bytes: Data("head".utf8), replaceable: false)
        let oldViewport = TerminalOutputDelivery(bytes: Data("old".utf8), replaceable: true)
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: -2, col: 0, row: 0)],
            receipt: TerminalSurfaceMutationReceipt()
        )
        let newViewport = TerminalOutputDelivery(bytes: Data("new".utf8), replaceable: true)
        let barrier = TerminalOutputDelivery(barrierReceipt: TerminalSurfaceMutationReceipt())
        let latestViewport = TerminalOutputDelivery(bytes: Data("latest".utf8), replaceable: true)

        #expect(queue.enqueue(head) == head)
        #expect(queue.enqueue(oldViewport) == nil)
        #expect(queue.enqueue(scroll) == nil)
        #expect(queue.enqueue(newViewport) == nil)
        #expect(queue.enqueue(barrier) == nil)
        #expect(queue.enqueue(latestViewport) == nil)

        #expect(queue.completeInFlight() == oldViewport)
        #expect(queue.completeInFlight() == scroll)
        #expect(queue.completeInFlight() == newViewport)
        #expect(queue.completeInFlight() == barrier)
        #expect(queue.completeInFlight() == latestViewport)
    }

    @Test("reset resolves outstanding mutation receipts")
    func resetResolvesMutationReceipts() async {
        var queue = TerminalOutputDeliveryQueue()
        let scrollReceipt = TerminalSurfaceMutationReceipt()
        let barrierReceipt = TerminalSurfaceMutationReceipt()
        let scroll = TerminalOutputDelivery(
            localScroll: [MobileTerminalScrollRun(lines: -3, col: 1, row: 1)],
            receipt: scrollReceipt
        )
        let barrier = TerminalOutputDelivery(barrierReceipt: barrierReceipt)
        _ = queue.enqueue(scroll)
        _ = queue.enqueue(barrier)

        queue.reset()

        #expect(await scrollReceipt.value == false)
        #expect(await barrierReceipt.value == false)
        #expect(queue.isIdle)
    }
}
