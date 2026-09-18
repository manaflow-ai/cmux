import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// The live terminal path must leave a per-event breadcrumb trail through the
/// diagnostic spine: one liveInput trace per marked input batch (dispatch,
/// settlement, watermark echo, presentation) and liveFrame discard records for
/// every gated frame, so an exported timeline can attribute keystroke latency
/// to a concrete stage instead of a guess.
@MainActor
@Suite struct MobileShellTerminalLiveTraceTests {
    private func makeStore() -> (MobileShellComposite, DiagnosticLog) {
        let log = DiagnosticLog(capacity: 64, role: .mobileClient)
        let store = MobileShellComposite(isSignedIn: true, diagnosticLog: log)
        return (store, log)
    }

    private func tracePhases(
        _ log: DiagnosticLog,
        operation: DiagnosticTerminalTraceOperation,
        traceID: UInt64? = nil
    ) async -> [Int] {
        await log.snapshot().events
            .filter {
                $0.code == .terminalTrace && $0.a == operation.rawValue
                    && (traceID == nil || $0.traceID == traceID)
            }
            .compactMap(\.b)
    }

    private func waitForTraceCount(
        _ log: DiagnosticLog,
        operation: DiagnosticTerminalTraceOperation,
        atLeast expected: Int
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await tracePhases(log, operation: operation).count < expected,
              clock.now < deadline {
            await Task.yield()
        }
    }

    @Test func liveInputTraceCoversDispatchSettlementEchoAndPresentation() async throws {
        let (store, log) = makeStore()
        store.traceLiveInputDispatched(surfaceID: "s1", sequence: 7)
        store.traceLiveInputSettled(surfaceID: "s1", sequence: 7, failed: false)
        store.traceLiveInputEchoAcknowledged(surfaceID: "s1", acknowledgedSequence: 7)
        store.traceLiveInputPresented(surfaceID: "s1", sequence: 7)
        await waitForTraceCount(log, operation: .liveInput, atLeast: 4)
        #expect(await tracePhases(log, operation: .liveInput, traceID: 7) == [
            DiagnosticTerminalTracePhase.started.rawValue,
            DiagnosticTerminalTracePhase.requestSent.rawValue,
            DiagnosticTerminalTracePhase.responseReceived.rawValue,
            DiagnosticTerminalTracePhase.presented.rawValue,
        ])
    }

    @Test func cumulativeWatermarkSettlesEveryOlderPendingTrace() async throws {
        let (store, log) = makeStore()
        for sequence: UInt64 in [5, 6, 7] {
            store.traceLiveInputDispatched(surfaceID: "s1", sequence: sequence)
        }
        store.traceLiveInputEchoAcknowledged(surfaceID: "s1", acknowledgedSequence: 7)
        await waitForTraceCount(log, operation: .liveInput, atLeast: 6)
        let echoed = await log.snapshot().events
            .filter {
                $0.code == .terminalTrace
                    && $0.a == DiagnosticTerminalTraceOperation.liveInput.rawValue
                    && $0.b == DiagnosticTerminalTracePhase.responseReceived.rawValue
            }
            .compactMap(\.traceID)
        #expect(Set(echoed) == [5, 6, 7])
    }

    @Test func failedSendSettlesTheTraceAsFailed() async throws {
        let (store, log) = makeStore()
        store.traceLiveInputDispatched(surfaceID: "s1", sequence: 9)
        store.traceLiveInputSettled(surfaceID: "s1", sequence: 9, failed: true)
        // A later ack for the failed marker records nothing: the trace ended.
        store.traceLiveInputEchoAcknowledged(surfaceID: "s1", acknowledgedSequence: 9)
        await waitForTraceCount(log, operation: .liveInput, atLeast: 2)
        #expect(await tracePhases(log, operation: .liveInput, traceID: 9) == [
            DiagnosticTerminalTracePhase.started.rawValue,
            DiagnosticTerminalTracePhase.failed.rawValue,
        ])
    }

    @Test func frameDiscardsAreAlwaysTracedWithTheirReason() async throws {
        let (store, log) = makeStore()
        store.traceLiveFrameDiscarded(surfaceID: "s1", stateSeq: 42, reason: .behindPendingInput)
        store.traceLiveFrameDiscarded(surfaceID: "s1", stateSeq: 43, reason: .staleSequence)
        await waitForTraceCount(log, operation: .liveFrame, atLeast: 2)
        let reasons = await log.snapshot().events
            .filter {
                $0.code == .terminalTrace
                    && $0.a == DiagnosticTerminalTraceOperation.liveFrame.rawValue
                    && $0.b == DiagnosticTerminalTracePhase.discarded.rawValue
            }
            .compactMap(\.c)
        #expect(reasons.sorted() == [
            DiagnosticTerminalTraceDiscardReason.staleSequence.rawValue,
            DiagnosticTerminalTraceDiscardReason.behindPendingInput.rawValue,
        ].sorted())
    }

    @Test func teardownClearsPendingLiveTraces() async throws {
        let (store, log) = makeStore()
        store.traceLiveInputDispatched(surfaceID: "s1", sequence: 11)
        store.clearLiveTerminalTraces()
        store.traceLiveInputEchoAcknowledged(surfaceID: "s1", acknowledgedSequence: 11)
        await waitForTraceCount(log, operation: .liveInput, atLeast: 1)
        #expect(await tracePhases(log, operation: .liveInput, traceID: 11) == [
            DiagnosticTerminalTracePhase.started.rawValue,
        ])
    }
}
