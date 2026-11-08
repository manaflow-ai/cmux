import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@MainActor
@Suite("Simulator live status watcher")
struct SimulatorLiveStatusWatcherTests {
    @Test("Visible panes refresh distinct foreground and camera state without overlap")
    func visibilityAndWorkerLifecycle() async {
        let client = LiveStatusPaneClient()
        let sleeper = LiveStatusSleepGate()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: sleeper
        )
        coordinator.setLiveStatusVisibility(false)
        await coordinator.start()
        await client.emit(.message(.capabilities([.foregroundApplication, .cameraInjection])))
        await client.emit(.message(.status(.streaming)))
        await eventually { coordinator.status == .streaming }
        #expect(await client.readCounts() == (0, 0))

        coordinator.setLiveStatusVisibility(true)
        await eventually {
            await client.readCounts() == (1, 1)
                && coordinator.foregroundApplication?.bundleIdentifier == "com.example.first"
                && coordinator.cameraStatus?.targetIsAttached == false
        }
        await sleeper.waitForStarts(1)

        await client.setSecondSnapshot()
        await sleeper.advance()
        await eventually {
            await client.readCounts() == (2, 2)
                && coordinator.foregroundApplication?.bundleIdentifier == "com.example.second"
                && coordinator.foregroundApplication?.processIdentifier == 202
                && coordinator.cameraStatus?.targetIsAttached == true
        }

        await client.setCameraFailure(true)
        await sleeper.advance()
        await eventually { await client.readCounts() == (3, 3) }
        await sleeper.waitForStarts(3)
        #expect(await sleeper.recordedDurations().last == .seconds(5))

        coordinator.setLiveStatusVisibility(false)
        await sleeper.waitForCancellations(1)
        let hiddenCounts = await client.readCounts()
        await Task.yield()
        #expect(await client.readCounts() == hiddenCounts)

        coordinator.setLiveStatusVisibility(true)
        await eventually { await client.readCounts().0 == hiddenCounts.0 + 1 }
        await sleeper.waitForStarts(4)
        await client.emit(.workerStopped)
        await sleeper.waitForCancellations(2)
        let crashedCounts = await client.readCounts()
        await Task.yield()

        #expect(await client.readCounts() == crashedCounts)
        #expect(await client.maximumConcurrentReads() == 1)
        await coordinator.close()
        #expect(await client.stopCount() == 1)
    }

    private func eventually(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}
