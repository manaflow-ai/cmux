@testable import CmuxNextApp
import CmuxNextDaemon
import Observation
import CmuxNextWakeups
import Testing

@MainActor
struct TabMirrorPlacementTests {
    /// The app's main-thread scheduler stand-in: the tree's arrival is observed on it.
    static let mainWork = MainWorkScheduler(budget: MainFrameBudget())

    @Observable final class Mirror {
        var present = false
    }

    @Test func aCreationReplyWaitsForTheTreeBeforePlacing() async {
        let mirror = Mirror(), daemon = DaemonService()
        let (reads, read) = AsyncStream<Void>.makeStream()
        var placements = 0
        let task = Task {
            await TabMirror.performWhenReached("waiting-chat", in: { key in
                read.yield()
                return key == "waiting-chat" && mirror.present ? (PaneID(rawValue: 1), daemon) : nil
            }, on: Self.mainWork) {
                placements += 1
                #expect(mirror.present, "placement ran before the tab reached the tree")
            }
        }
        for await _ in reads { break }
        #expect(placements == 0)
        mirror.present = true
        await task.value
        read.finish()
        #expect(placements == 1, "the creation reply lost its placement before the tree arrived")
    }

    @Test func anAlreadyMirroredTabPlacesExactlyOnce() async {
        let daemon = DaemonService()
        var placements = 0
        await TabMirror.performWhenReached("waiting-chat", in: { _ in (PaneID(rawValue: 1), daemon) }, on: Self.mainWork) {
            placements += 1
        }
        #expect(placements == 1)
    }

    @Test func cancellationBeforeTreeArrivalNeverPlaces() async {
        let mirror = Mirror(), daemon = DaemonService()
        let (reads, read) = AsyncStream<Void>.makeStream()
        var placements = 0
        let task = Task {
            await TabMirror.performWhenReached("waiting-chat", in: { _ in
                read.yield()
                return mirror.present ? (PaneID(rawValue: 1), daemon) : nil
            }, on: Self.mainWork) { placements += 1 }
        }
        for await _ in reads { break }
        task.cancel()
        await task.value
        mirror.present = true
        read.finish()
        #expect(placements == 0)
    }
}
