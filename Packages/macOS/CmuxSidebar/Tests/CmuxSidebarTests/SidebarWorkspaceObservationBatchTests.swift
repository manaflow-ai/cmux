import Foundation
import Testing
@testable import CmuxSidebar

@Suite
struct SidebarWorkspaceObservationBatchTests {
    @Test
    func leadingAndTrailingDeliveriesStayLosslessDuringSustainedChurn() async {
        let clock = SidebarWorkspaceObservationTestClock()
        let batch = SidebarWorkspaceObservationBatch(
            deliveryInterval: .seconds(1),
            clock: clock
        )
        var changes = batch.changes.makeAsyncIterator()
        let noisyWorkspaceId = UUID()
        let quietWorkspaceId = UUID()

        await batch.record(noisyWorkspaceId)
        #expect(await changes.next() == [noisyWorkspaceId])
        await clock.waitUntilSleepers()

        await batch.record(quietWorkspaceId)
        await batch.record(noisyWorkspaceId)
        clock.advance(by: .seconds(1))
        #expect(await changes.next() == [noisyWorkspaceId, quietWorkspaceId])

        for _ in 0..<3 {
            await clock.waitUntilSleepers()
            await batch.record(noisyWorkspaceId)
            clock.advance(by: .seconds(1))
            #expect(await changes.next() == [noisyWorkspaceId])
        }

        await batch.cancel()
        #expect(await changes.next() == nil)
    }

    @Test
    func displacedBufferedBatchIsUnionedWithoutSelfSustainingPacing() async {
        let clock = SidebarWorkspaceObservationTestClock()
        let batch = SidebarWorkspaceObservationBatch(
            deliveryInterval: .seconds(1),
            clock: clock
        )
        var changes = batch.changes.makeAsyncIterator()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()

        await batch.record(firstWorkspaceId)
        await clock.waitUntilSleepers()
        await batch.record(secondWorkspaceId)
        clock.advance(by: .seconds(1))

        await clock.waitUntilSleepers()
        #expect(await changes.next() == [firstWorkspaceId, secondWorkspaceId])
        clock.advance(by: .seconds(1))

        let thirdWorkspaceId = UUID()
        await batch.record(thirdWorkspaceId)
        #expect(await changes.next() == [thirdWorkspaceId])

        await batch.cancel()
    }

    @Test
    func cancellationFinishesTheStreamAndCancelsThePacingWait() async {
        let clock = SidebarWorkspaceObservationTestClock()
        let batch = SidebarWorkspaceObservationBatch(
            deliveryInterval: .seconds(1),
            clock: clock
        )
        var changes = batch.changes.makeAsyncIterator()
        let workspaceId = UUID()

        await batch.record(workspaceId)
        #expect(await changes.next() == [workspaceId])
        await clock.waitUntilSleepers()

        await batch.cancel()

        #expect(clock.sleeperCount() == 0)
        #expect(await changes.next() == nil)
    }
}
