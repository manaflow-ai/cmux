import Foundation
import Testing

@testable import CmuxRemoteSession

@Suite struct RemoteTmuxCatchUpCoordinatorTests {
    @Test func aRequestWaitsForTheRunningCatchUpsLastSeed() {
        var catchUp = RemoteTmuxCatchUpCoordinator()
        catchUp.request()
        #expect(catchUp.shouldStart)
        catchUp.begin()
        let seeds = [UUID(), UUID()]
        for seed in seeds { catchUp.track(seedID: seed) }
        #expect(!catchUp.shouldStart)

        catchUp.request()
        catchUp.seedEnded(seeds[0])
        #expect(!catchUp.shouldStart, "started while a catch-up seed was still waiting on tmux")
        catchUp.seedEnded(seeds[1])
        #expect(catchUp.shouldStart)
    }

    @Test func aPaneQueuedForItsSeedDropsOutputUntilTheSeedStarts() {
        var catchUp = RemoteTmuxCatchUpCoordinator()
        catchUp.begin()
        catchUp.awaitSeed(forPane: 9)
        catchUp.request()
        #expect(catchUp.dropsOutput(forPane: 9))
        #expect(!catchUp.dropsOutput(forPane: 7))
        #expect(!catchUp.shouldStart, "started while a pane still waited for its seed")

        let unrelatedSeedJoined = catchUp.seedStarted(UUID(), forPane: 7)
        #expect(!unrelatedSeedJoined)
        let seed = UUID()
        let queuedSeedJoined = catchUp.seedStarted(seed, forPane: 9)
        #expect(queuedSeedJoined)
        #expect(!catchUp.dropsOutput(forPane: 9))
        #expect(!catchUp.shouldStart)
        catchUp.seedEnded(seed)
        #expect(catchUp.shouldStart)
    }

    @Test func removedPanesStopHoldingTheCatchUp() {
        var catchUp = RemoteTmuxCatchUpCoordinator()
        catchUp.begin()
        for pane in [1, 2, 3] { catchUp.awaitSeed(forPane: pane) }
        catchUp.request()
        catchUp.paneRemoved(1)
        #expect(!catchUp.dropsOutput(forPane: 1))
        catchUp.retainPanes([3])
        #expect(!catchUp.dropsOutput(forPane: 2))
        #expect(catchUp.dropsOutput(forPane: 3))
        catchUp.paneRemoved(3)
        #expect(catchUp.shouldStart)
    }

    @Test func resetForgetsTheRequestAndEverythingItWaitedOn() {
        var catchUp = RemoteTmuxCatchUpCoordinator()
        catchUp.request()
        catchUp.track(seedID: UUID())
        catchUp.awaitSeed(forPane: 4)
        catchUp.reset()
        #expect(catchUp == RemoteTmuxCatchUpCoordinator())
    }

    /// A thousand panes: the request starts exactly when the last of a thousand seeds ends.
    @Test func aThousandPaneCatchUpStartsTheNextOneOnlyAfterItsLastSeed() {
        var catchUp = RemoteTmuxCatchUpCoordinator()
        catchUp.begin()
        let seeds = (0..<1_000).map { _ in UUID() }
        for seed in seeds { catchUp.track(seedID: seed) }
        catchUp.request()
        var startedAfter: [Int] = []
        for (index, seed) in seeds.enumerated() {
            catchUp.seedEnded(seed)
            if catchUp.shouldStart { startedAfter.append(index) }
        }
        #expect(startedAfter == [999])
    }
}
