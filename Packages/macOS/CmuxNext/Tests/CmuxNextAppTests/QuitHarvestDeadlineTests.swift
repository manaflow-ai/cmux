import CmuxNextDaemonService
import Foundation
import Testing

@testable import CmuxNextApp

/// The quit's error harvest (an `OSLogStore` read over the whole run, seconds after a long
/// session) never holds up the quit: the engines start to stop, and the quit deadline is armed
/// (`QuitDeadline`, in `stopBrowserEngines`), whatever the harvest does. Before, QuitCompletion
/// awaited the harvest before it stopped the engines, with no limit on it.
@MainActor
@Suite struct QuitHarvestDeadlineTests {
    /// The steps in the order they ran.
    @MainActor final class Order {
        var steps: [String] = []
    }

    @Test(.timeLimit(.minutes(1))) func theEnginesStopWhileTheHarvestStillRuns() async {
        let order = Order()
        let (engines, enginesStopped) = AsyncStream<Void>.makeStream()
        await QuitCompletion.run(.keep, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: {},
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            stopBrowserEngines: {
                order.steps.append("engines")
                enginesStopped.yield()
                enginesStopped.finish()
            },
            harvestErrors: {
                order.steps.append("harvest started")
                // The harvest ends only once the engines began to stop: before the fix the quit
                // waited for it first and never got there (the time limit fails the test).
                for await _ in engines {}
                order.steps.append("harvest ended")
            }
        ))
        // The harvest may start before or after the engines (a child task); it ends after them.
        #expect(order.steps.last == "harvest ended")
        #expect(order.steps.firstIndex(of: "engines").map { $0 < order.steps.count - 1 } == true)
    }
}
