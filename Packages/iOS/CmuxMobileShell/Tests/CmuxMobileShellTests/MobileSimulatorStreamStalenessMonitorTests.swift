import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
private final class StaleRecorder {
    private(set) var panelIDs: [String] = []
    func record(_ panelID: String) {
        panelIDs.append(panelID)
    }
}

@MainActor
@Suite struct MobileSimulatorStreamStalenessMonitorTests {
    @Test func firesAfterSilentThreshold() async throws {
        let clock = ControlPoolManualClock()
        let recorder = StaleRecorder()
        let monitor = MobileSimulatorStreamStalenessMonitor(
            clock: clock,
            threshold: .seconds(15)
        ) { recorder.record($0) }
        monitor.arm(panelID: "sim-1")
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(15))

        #expect(try await pollUntil { recorder.panelIDs == ["sim-1"] })
    }

    @Test func activityWithinThresholdPreventsFiring() async throws {
        let clock = ControlPoolManualClock()
        let recorder = StaleRecorder()
        let monitor = MobileSimulatorStreamStalenessMonitor(
            clock: clock,
            threshold: .seconds(15)
        ) { recorder.record($0) }
        monitor.arm(panelID: "sim-1")
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        monitor.recordActivity(panelID: "sim-1")
        clock.advance(by: .seconds(15))

        // The watcher loops back to sleep without firing.
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        #expect(recorder.panelIDs.isEmpty)

        // A following interval with no activity fires.
        clock.advance(by: .seconds(15))
        #expect(try await pollUntil { recorder.panelIDs == ["sim-1"] })
    }

    /// A recovery attempt that itself dies silently must retry: the watcher
    /// keeps sampling after a fire instead of standing down.
    @Test func keepsFiringWhileSilenceContinues() async throws {
        let clock = ControlPoolManualClock()
        let recorder = StaleRecorder()
        let monitor = MobileSimulatorStreamStalenessMonitor(
            clock: clock,
            threshold: .seconds(15)
        ) { recorder.record($0) }
        monitor.arm(panelID: "sim-1")
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(15))
        #expect(try await pollUntil { recorder.panelIDs == ["sim-1"] })

        #expect(try await pollUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(15))
        #expect(try await pollUntil { recorder.panelIDs == ["sim-1", "sim-1"] })
    }

    @Test func disarmStopsWatching() async throws {
        let clock = ControlPoolManualClock()
        let recorder = StaleRecorder()
        let monitor = MobileSimulatorStreamStalenessMonitor(
            clock: clock,
            threshold: .seconds(15)
        ) { recorder.record($0) }
        monitor.arm(panelID: "sim-1")
        #expect(try await pollUntil { clock.sleeperCount == 1 })

        monitor.disarm(panelID: "sim-1")
        clock.advance(by: .seconds(30))

        #expect(try await pollUntil { clock.sleeperCount == 0 })
        #expect(recorder.panelIDs.isEmpty)
    }

    @Test func activityForUnarmedPanelIsIgnored() async throws {
        let clock = ControlPoolManualClock()
        let recorder = StaleRecorder()
        let monitor = MobileSimulatorStreamStalenessMonitor(
            clock: clock,
            threshold: .seconds(15)
        ) { recorder.record($0) }

        monitor.recordActivity(panelID: "sim-other")
        monitor.arm(panelID: "sim-1")
        #expect(try await pollUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(15))

        #expect(try await pollUntil { recorder.panelIDs == ["sim-1"] })
    }
}
