import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TerminalRenderStallMonitorTests {
    @Test func dropEpisodeEmitsOneStallAtThreshold() {
        let start = Date(timeIntervalSince1970: 100)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        #expect(monitor.noteFrameDropped(surface: 7, gate: .pendingInputSeq, now: start).isEmpty)
        #expect(monitor.noteFrameDropped(
            surface: 7,
            gate: .pendingInputSeq,
            now: start.addingTimeInterval(4.9)
        ).isEmpty)

        let first = monitor.noteFrameDropped(
            surface: 7,
            gate: .pendingInputSeq,
            now: start.addingTimeInterval(5)
        )
        #expect(first == [.stallDetected(
            surface: 7,
            gate: .pendingInputSeq,
            droppedFrames: 3,
            stallDuration: 5
        )])

        let repeated = monitor.noteFrameDropped(
            surface: 7,
            gate: .pendingInputSeq,
            now: start.addingTimeInterval(10)
        )
        #expect(repeated.isEmpty)
    }

    @Test func frameAppliedUpdatesTimestampWithoutResolvingEpisodes() {
        let start = Date(timeIntervalSince1970: 200)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        _ = monitor.noteFrameDropped(surface: 1, gate: .replayBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 1, gate: .replayBarrier, now: start.addingTimeInterval(6))
        monitor.noteFrameApplied(surface: 1, now: start.addingTimeInterval(7))

        #expect(monitor.secondsSinceLastAppliedFrame(surface: 1, now: start.addingTimeInterval(10)) == 3)
        #expect(monitor.snapshot(surface: 1, now: start.addingTimeInterval(8)).count == 1)
        let recovered = monitor.noteGateResolved(
            surface: 1,
            gate: .replayBarrier,
            how: .replayAck,
            now: start.addingTimeInterval(9)
        )
        #expect(recovered == [.stallRecovered(
            surface: 1,
            gate: .replayBarrier,
            how: .replayAck,
            duration: 9,
            droppedFrames: 2
        )])

        _ = monitor.noteFrameDropped(surface: 1, gate: .baselineWait, now: start.addingTimeInterval(9))
        monitor.noteFrameApplied(surface: 1, now: start.addingTimeInterval(10))
        #expect(monitor.snapshot(surface: 1, now: start.addingTimeInterval(10)).count == 1)
    }

    @Test func gateResolvedRecoversOnlyNamedGate() {
        let start = Date(timeIntervalSince1970: 300)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 1)

        _ = monitor.noteFrameDropped(surface: 5, gate: .pendingInputSeq, now: start)
        _ = monitor.noteFrameDropped(surface: 5, gate: .replayBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 6, gate: .viewportBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 5, gate: .pendingInputSeq, now: start.addingTimeInterval(2))
        _ = monitor.noteFrameDropped(surface: 5, gate: .replayBarrier, now: start.addingTimeInterval(2))
        _ = monitor.noteFrameDropped(surface: 6, gate: .viewportBarrier, now: start.addingTimeInterval(2))

        let recovered = monitor.noteGateResolved(
            surface: 5,
            gate: .replayBarrier,
            how: .replayAck,
            now: start.addingTimeInterval(3)
        )

        #expect(recovered == [.stallRecovered(
            surface: 5,
            gate: .replayBarrier,
            how: .replayAck,
            duration: 3,
            droppedFrames: 2
        )])
        let remaining = monitor.snapshot(surface: 5, now: start.addingTimeInterval(4))
        #expect(remaining == [TerminalRenderStallSnapshot(
            surface: 5,
            gate: .pendingInputSeq,
            droppedFrames: 2,
            duration: 4,
            stallDetected: true
        )])
        #expect(monitor.snapshot(surface: 6, now: start.addingTimeInterval(3)).count == 1)
    }

    @Test func surfaceResolvedRecoversAllDetectedGatesForSurface() {
        let start = Date(timeIntervalSince1970: 350)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 1)

        _ = monitor.noteFrameDropped(surface: 5, gate: .pendingInputSeq, now: start)
        _ = monitor.noteFrameDropped(surface: 5, gate: .replayBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 6, gate: .viewportBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 5, gate: .pendingInputSeq, now: start.addingTimeInterval(2))
        _ = monitor.noteFrameDropped(surface: 5, gate: .replayBarrier, now: start.addingTimeInterval(2))
        _ = monitor.noteFrameDropped(surface: 6, gate: .viewportBarrier, now: start.addingTimeInterval(2))

        let recovered = monitor.noteSurfaceResolved(
            surface: 5,
            how: .resync,
            now: start.addingTimeInterval(3)
        )

        #expect(recovered.count == 2)
        #expect(recovered.contains(.stallRecovered(
            surface: 5,
            gate: .pendingInputSeq,
            how: .resync,
            duration: 3,
            droppedFrames: 2
        )))
        #expect(recovered.contains(.stallRecovered(
            surface: 5,
            gate: .replayBarrier,
            how: .resync,
            duration: 3,
            droppedFrames: 2
        )))
        #expect(monitor.snapshot(surface: 6, now: start.addingTimeInterval(3)).count == 1)
    }

    @Test func resyncTriggerAttributesEventualGateRecovery() {
        let start = Date(timeIntervalSince1970: 375)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 1)

        _ = monitor.noteFrameDropped(surface: 4, gate: .replayBarrier, now: start)
        _ = monitor.noteFrameDropped(surface: 4, gate: .replayBarrier, now: start.addingTimeInterval(2))
        monitor.noteResyncTriggered(surface: 4, now: start.addingTimeInterval(3))

        let recovered = monitor.noteGateResolved(
            surface: 4,
            gate: .replayBarrier,
            how: .replayAck,
            now: start.addingTimeInterval(4)
        )

        #expect(recovered == [.stallRecovered(
            surface: 4,
            gate: .replayBarrier,
            how: .resync,
            duration: 4,
            droppedFrames: 2
        )])
    }

    @Test func resyncAttributionDoesNotApplyToEpisodeOpenedAfterMark() {
        let start = Date(timeIntervalSince1970: 385)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 1)

        _ = monitor.noteFrameDropped(surface: 4, gate: .pendingInputSeq, now: start)
        _ = monitor.noteFrameDropped(surface: 4, gate: .pendingInputSeq, now: start.addingTimeInterval(2))
        monitor.noteResyncTriggered(surface: 4, now: start.addingTimeInterval(3))
        _ = monitor.noteFrameDropped(surface: 4, gate: .replayBarrier, now: start.addingTimeInterval(4))
        _ = monitor.noteFrameDropped(surface: 4, gate: .replayBarrier, now: start.addingTimeInterval(6))

        let replayRecovered = monitor.noteGateResolved(
            surface: 4,
            gate: .replayBarrier,
            how: .replayAck,
            now: start.addingTimeInterval(7)
        )
        let pendingRecovered = monitor.noteGateResolved(
            surface: 4,
            gate: .pendingInputSeq,
            how: .catchupFrame,
            now: start.addingTimeInterval(8)
        )

        #expect(replayRecovered == [.stallRecovered(
            surface: 4,
            gate: .replayBarrier,
            how: .replayAck,
            duration: 3,
            droppedFrames: 2
        )])
        #expect(pendingRecovered == [.stallRecovered(
            surface: 4,
            gate: .pendingInputSeq,
            how: .resync,
            duration: 8,
            droppedFrames: 2
        )])
    }

    @Test func gateReplacementMergesDetectedEpisodeWithoutDuplicateEmission() {
        let start = Date(timeIntervalSince1970: 390)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        _ = monitor.noteFrameDropped(surface: 2, gate: .pendingInputSeq, now: start)
        let detected = monitor.noteFrameDropped(
            surface: 2,
            gate: .pendingInputSeq,
            now: start.addingTimeInterval(6)
        )
        _ = monitor.noteFrameDropped(surface: 2, gate: .replayBarrier, now: start.addingTimeInterval(5))

        monitor.noteGateReplaced(
            surface: 2,
            from: [.pendingInputSeq],
            to: .replayBarrier,
            now: start.addingTimeInterval(7)
        )

        #expect(detected == [.stallDetected(
            surface: 2,
            gate: .pendingInputSeq,
            droppedFrames: 2,
            stallDuration: 6
        )])
        #expect(monitor.snapshot(surface: 2, now: start.addingTimeInterval(8)) == [
            TerminalRenderStallSnapshot(
                surface: 2,
                gate: .replayBarrier,
                droppedFrames: 3,
                duration: 8,
                stallDetected: true
            ),
        ])
        #expect(monitor.noteFrameDropped(
            surface: 2,
            gate: .replayBarrier,
            now: start.addingTimeInterval(9)
        ).isEmpty)

        let recovered = monitor.noteGateResolved(
            surface: 2,
            gate: .replayBarrier,
            how: .replayAck,
            now: start.addingTimeInterval(10)
        )
        #expect(recovered == [.stallRecovered(
            surface: 2,
            gate: .replayBarrier,
            how: .replayAck,
            duration: 10,
            droppedFrames: 4
        )])
    }

    @Test func gateReplacementKeepsUndetectedEpisodeAgingFromEarliestStart() {
        let start = Date(timeIntervalSince1970: 395)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        _ = monitor.noteFrameDropped(surface: 2, gate: .baselineWait, now: start)
        monitor.noteGateReplaced(
            surface: 2,
            from: [.baselineWait],
            to: .replayBarrier,
            now: start.addingTimeInterval(2)
        )

        #expect(monitor.noteFrameDropped(
            surface: 2,
            gate: .replayBarrier,
            now: start.addingTimeInterval(4.9)
        ).isEmpty)
        #expect(monitor.noteFrameDropped(
            surface: 2,
            gate: .replayBarrier,
            now: start.addingTimeInterval(5)
        ) == [.stallDetected(
            surface: 2,
            gate: .replayBarrier,
            droppedFrames: 3,
            stallDuration: 5
        )])
    }

    @Test func snapshotReportsActiveGateBitmaskAndLastAppliedAge() {
        let start = Date(timeIntervalSince1970: 400)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        monitor.noteFrameApplied(surface: 9, now: start)
        _ = monitor.noteFrameDropped(surface: 9, gate: .pendingInputSeq, now: start.addingTimeInterval(1))
        _ = monitor.noteFrameDropped(surface: 9, gate: .viewportBarrier, now: start.addingTimeInterval(2))

        #expect(monitor.activeGateBitmask(surface: 9) == TerminalRenderDropGate.pendingInputSeq.bit | TerminalRenderDropGate.viewportBarrier.bit)
        #expect(monitor.activeGates(now: start.addingTimeInterval(3))[9] == [.pendingInputSeq, .viewportBarrier])
        #expect(monitor.secondsSinceLastAppliedFrame(surface: 9, now: start.addingTimeInterval(3)) == 3)
    }

    @Test func surfaceResolvedPurgesLastAppliedFrameClock() {
        let start = Date(timeIntervalSince1970: 500)
        var monitor = TerminalRenderStallMonitor(stallThreshold: 5)

        monitor.noteFrameApplied(surface: 4, now: start)
        _ = monitor.noteSurfaceResolved(surface: 4, how: .reconnect, now: start.addingTimeInterval(1))

        #expect(monitor.secondsSinceLastAppliedFrame(surface: 4, now: start.addingTimeInterval(2)) == nil)
    }
}
