import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The failure these cover is a surface that stopped asking for content.
/// Once the retry budget is spent the barrier fails open, live output resumes
/// and nothing re-requests a replay, so an idle terminal stays blank until a
/// remount or relaunch. Every other terminal trace watches a replay that is in
/// flight, so that state produced no telemetry at all.
@MainActor
@Suite struct TerminalBlankSurfaceWatchdogTests {
    private func makeBlankMountedStore(
        surfaceID: String
    ) -> (CMUXMobileShellStore, AsyncStream<MobileTerminalOutputChunk>) {
        let store = MobileShellComposite.preview()
        let stream = store.terminalOutputStream(surfaceID: surfaceID)
        // A surface rebuilt blank: no delivered baseline, hydration owed.
        store.terminalMirrorHydrationNeededSurfaceIDs.insert(surfaceID)
        store.deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        return (store, stream)
    }

    @Test func aBlankSurfaceWithNothingRepairingItIsReported() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        #expect(store.terminalSurfaceIsUnattendedBlank(surfaceID: surfaceID))
        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .retryExhausted)
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] != nil)
    }

    /// Blank alone is normal while a replay is on its way. Only blank with
    /// nothing outstanding means nobody is coming.
    @Test func aBlankSurfaceWithAReplayInFlightIsNotReported() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        store.terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        #expect(store.terminalSurfaceIsUnattendedBlank(surfaceID: surfaceID) == false)
        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .retryExhausted)
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] == nil)
    }

    @Test func aBlankSurfaceBehindAReplayBarrierIsNotReported() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] = UUID()
        #expect(store.terminalSurfaceIsUnattendedBlank(surfaceID: surfaceID) == false)
    }

    /// An unmounted surface is nobody's blank screen.
    @Test func anUnmountedSurfaceIsNotReported() {
        let store = MobileShellComposite.preview()
        store.terminalMirrorHydrationNeededSurfaceIDs.insert("never-mounted")
        #expect(store.terminalSurfaceIsUnattendedBlank(surfaceID: "never-mounted") == false)
    }

    @Test func contentArrivingClosesTheReport() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .barrierFailedOpen)
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] != nil)

        store.terminalMirrorHydrationNeededSurfaceIDs.remove(surfaceID)
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = 42
        store.evaluateTerminalBlankSurfaceWatchdog(surfaceID: surfaceID)

        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] == nil)
        #expect(store.terminalBlankSurfaceWatchdogTasksBySurfaceID[surfaceID] == nil)
    }

    /// A replay taking over ends the unattended condition. If the report is
    /// not closed here the probe exits at its next mark and leaves the task
    /// mapping behind, which silently blocks every later report for this
    /// surface.
    @Test func aReplayTakingOverClosesTheReportAndFreesTheSurface() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .retryExhausted)
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] != nil)

        store.markTerminalReplayInFlight(
            surfaceID: surfaceID,
            requestID: UUID(),
            replayBarrierToken: nil
        )
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] == nil)
        #expect(store.terminalBlankSurfaceWatchdogTasksBySurfaceID[surfaceID] == nil)

        // The surface is free to report again once the replay settles blank.
        store.terminalReplaySurfaceIDsInFlight.remove(surfaceID)
        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .retryExhausted)
        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] != nil)
    }

    /// One blank episode is one report. Re-evaluating while still blank must
    /// not mint a second trace, or the duration restarts and Axiom shows a
    /// string of short blanks instead of one long one.
    @Test func aContinuingBlankKeepsOneReport() {
        let surfaceID = "blank-terminal"
        let (store, stream) = makeBlankMountedStore(surfaceID: surfaceID)
        defer { _ = stream }

        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .retryExhausted)
        let first = store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID]
        store.evaluateTerminalBlankSurfaceWatchdog(surfaceID: surfaceID)
        store.recordTerminalSurfaceGaveUp(surfaceID: surfaceID, trigger: .barrierFailedOpen)

        #expect(store.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] == first)
    }
}
