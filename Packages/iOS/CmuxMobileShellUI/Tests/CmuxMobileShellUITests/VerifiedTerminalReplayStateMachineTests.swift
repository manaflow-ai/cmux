import CMUXMobileCore
import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Foundation
import Testing

@MainActor
@Suite("Verified terminal replay")
struct VerifiedTerminalReplayStateMachineTests {
    @Test("a mismatched replay keeps the last verified frame visible")
    func mismatchNeverCommits() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let original = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(original, to: machine)

        let target = try frame(renderRevision: 2, stateSeq: 1, columns: 80, text: "expected next")
        let transaction = try #require(extractTransaction(from: machine.begin(frame: target)))
        let mismatched = try frame(renderRevision: 2, stateSeq: 1, columns: 80, text: "corrupted replay")

        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: mismatched)
                == .keepFrozenAndRequestReplay
        )
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "last good")
        #expect(machine.isFrozen)
    }

    @Test("a semantically identical replay commits despite reassigned style IDs")
    func validReplayCommits() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let source = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "verified", styleID: 1)
        let transaction = try #require(extractTransaction(from: machine.begin(frame: source)))
        let observed = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "verified", styleID: 9)

        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: observed)
                == .reveal
        )
        #expect(machine.visibleSnapshot?.rows.first?.first?.style.bold == true)
        #expect(!machine.isFrozen)
    }

    @Test("recovery rejects deltas until a full frame verifies")
    func recoveryRequiresFullFrame() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let original = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(original, to: machine)

        let failedTarget = try frame(
            renderRevision: 2,
            stateSeq: 2,
            columns: 80,
            text: "failed target"
        )
        let failedTransaction = try #require(
            extractTransaction(from: machine.begin(frame: failedTarget))
        )
        let mismatch = try frame(
            renderRevision: 2,
            stateSeq: 2,
            columns: 80,
            text: "mismatch"
        )
        #expect(
            machine.complete(
                transactionID: failedTransaction.id,
                observedFrame: mismatch
            ) == .keepFrozenAndRequestReplay
        )

        let partialDuringRecovery = try frame(
            renderRevision: 3,
            stateSeq: 3,
            columns: 80,
            text: "partial must stay hidden",
            full: false
        )
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: partialDuringRecovery) else {
            Issue.record("recovery must reject partial render grids")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "last good")
        #expect(machine.isFrozen)

        let recovered = try frame(
            renderRevision: 4,
            stateSeq: 4,
            columns: 80,
            text: "authoritative recovery"
        )
        commit(recovered, to: machine)
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "authoritative recovery")
        #expect(!machine.isFrozen)

        let partialAfterRecovery = try frame(
            renderRevision: 5,
            stateSeq: 5,
            columns: 80,
            text: "partial after recovery",
            full: false
        )
        guard case .apply = machine.begin(frame: partialAfterRecovery) else {
            Issue.record("verified deltas should resume after a full recovery frame")
            return
        }
    }

    @Test("a stale completion cannot reveal over a newer replay")
    func staleCompletionCannotReveal() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let first = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "first")
        let firstTransaction = try #require(extractTransaction(from: machine.begin(frame: first)))
        let second = try frame(renderRevision: 2, stateSeq: 1, columns: 80, text: "second")
        let secondTransaction = try #require(extractTransaction(from: machine.begin(frame: second)))

        #expect(
            machine.complete(transactionID: firstTransaction.id, observedFrame: first)
                == .ignoreStaleCompletion
        )
        #expect(machine.activeTransactionID == secondTransaction.id)
        #expect(machine.visibleSnapshot == nil)
        #expect(machine.isFrozen)
    }

    @Test("a viewport acknowledgement rejects frames captured before the resize settled")
    func viewportAcknowledgementRejectsOlderCapture() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let oldGrid = try frame(
            renderEpoch: "epoch-resize",
            renderRevision: 40,
            stateSeq: 9,
            columns: 41,
            text: "old narrow grid"
        )
        commit(oldGrid, to: machine)

        machine.acknowledgeViewport(
            renderEpoch: "epoch-resize",
            renderRevisionFloor: 42
        )

        let delayedOldGrid = try frame(
            renderEpoch: "epoch-resize",
            renderRevision: 42,
            stateSeq: 9,
            columns: 41,
            text: "delayed old narrow grid"
        )
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: delayedOldGrid) else {
            Issue.record("a frame at the pre-resize capture floor must never be presented")
            return
        }

        let settledGrid = try frame(
            renderEpoch: "epoch-resize",
            renderRevision: 43,
            stateSeq: 9,
            columns: 70,
            text: "settled phone grid"
        )
        let transaction = try #require(extractTransaction(from: machine.begin(frame: settledGrid)))
        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: settledGrid) == .reveal
        )
        #expect(machine.visibleSnapshot?.columns == 70)
    }

    @Test("a viewport acknowledgement invalidates a replay already applying at the old floor")
    func viewportAcknowledgementInvalidatesInFlightCapture() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let oldGrid = try frame(
            renderEpoch: "epoch-resize",
            renderRevision: 11,
            stateSeq: 2,
            columns: 41,
            text: "in flight old grid"
        )
        let transaction = try #require(extractTransaction(from: machine.begin(frame: oldGrid)))

        machine.acknowledgeViewport(
            renderEpoch: "epoch-resize",
            renderRevisionFloor: 11
        )

        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: oldGrid)
                == .ignoreStaleCompletion
        )
        #expect(machine.isFrozen)
        #expect(machine.visibleSnapshot == nil)
    }

    @Test("a width change presents only the old or fully verified new grid")
    func widthChangeIsAtomic() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let wide = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "wide frame")
        commit(wide, to: machine)

        let narrow = try frame(renderRevision: 2, stateSeq: 1, columns: 40, text: "narrow frame")
        let transaction = try #require(extractTransaction(from: machine.begin(frame: narrow)))

        #expect(machine.visibleSnapshot?.columns == 80)
        #expect(machine.targetDimensions == .init(columns: 40, rows: 3))
        #expect(machine.isFrozen)

        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: narrow)
                == .reveal
        )
        #expect(machine.visibleSnapshot?.columns == 40)
        #expect(!machine.isFrozen)
    }

    @Test("a new producer epoch may restart at revision one without reviving the retired epoch")
    func producerEpochResetIsOrdered() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let beforeReconnect = try frame(
            renderEpoch: "epoch-before-reconnect",
            renderRevision: 42,
            stateSeq: 9,
            columns: 80,
            text: "before reconnect"
        )
        commit(beforeReconnect, to: machine)

        let afterReconnect = try frame(
            renderEpoch: "epoch-after-reconnect",
            renderRevision: 1,
            stateSeq: 0,
            columns: 80,
            text: "after reconnect"
        )
        let reconnectTransaction = try #require(
            extractTransaction(from: machine.begin(frame: afterReconnect))
        )
        #expect(
            machine.complete(
                transactionID: reconnectTransaction.id,
                observedFrame: afterReconnect
            ) == .reveal
        )
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "after reconnect")

        let delayedOldEpoch = try frame(
            renderEpoch: "epoch-before-reconnect",
            renderRevision: 43,
            stateSeq: 10,
            columns: 80,
            text: "delayed old epoch"
        )
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: delayedOldEpoch) else {
            Issue.record("a retired producer epoch must never become visible again")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "after reconnect")
    }

    @Test("verified replay rejects missing capture identity")
    func missingCaptureIdentityFailsClosed() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let missingEpoch = try frame(
            renderEpoch: "",
            renderRevision: 1,
            stateSeq: 1,
            columns: 80,
            text: "missing epoch"
        )
        let zeroRevision = try frame(
            renderEpoch: "epoch",
            renderRevision: 0,
            stateSeq: 1,
            columns: 80,
            text: "missing revision"
        )

        guard case .keepFrozenAndRequestReplay = machine.begin(frame: missingEpoch) else {
            Issue.record("verified replay must reject a missing producer epoch")
            return
        }
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: zeroRevision) else {
            Issue.record("verified replay must reject revision zero")
            return
        }
        #expect(machine.visibleSnapshot == nil)
        #expect(machine.isFrozen)
    }

    @Test("verified transport cannot route missing or legacy frames around verification")
    func verifiedTransportRoutingFailsClosed() throws {
        let token = UUID()
        let missingFrame = MobileTerminalOutputChunk(
            data: Data("raw bypass".utf8),
            streamToken: token,
            requiresVerifiedReplay: true
        )
        #expect(terminalOutputApplicationPath(
            for: missingFrame,
            expectedSurfaceID: "surface-verified-replay"
        ) == .rejectUnverified)

        let zeroRevisionFrame = try frame(
            renderEpoch: "epoch",
            renderRevision: 0,
            stateSeq: 1,
            columns: 80,
            text: "legacy frame"
        )
        let zeroRevisionChunk = MobileTerminalOutputChunk(
            data: zeroRevisionFrame.vtPatchBytes(),
            streamToken: token,
            sourceRenderGridFrame: zeroRevisionFrame,
            requiresVerifiedReplay: true
        )
        #expect(terminalOutputApplicationPath(
            for: zeroRevisionChunk,
            expectedSurfaceID: "surface-verified-replay"
        ) == .rejectUnverified)

        let verifiedFrame = try frame(
            renderEpoch: "epoch",
            renderRevision: 1,
            stateSeq: 1,
            columns: 80,
            text: "verified frame"
        )
        let verifiedChunk = MobileTerminalOutputChunk(
            data: verifiedFrame.vtPatchBytes(),
            streamToken: token,
            sourceRenderGridFrame: verifiedFrame,
            requiresVerifiedReplay: true
        )
        #expect(terminalOutputApplicationPath(
            for: verifiedChunk,
            expectedSurfaceID: "surface-verified-replay"
        ) == .verifiedReplay)

        let unnegotiatedChunk = MobileTerminalOutputChunk(
            data: verifiedFrame.vtPatchBytes(),
            streamToken: token,
            sourceRenderGridFrame: verifiedFrame,
            requiresVerifiedReplay: false
        )
        #expect(terminalOutputApplicationPath(
            for: unnegotiatedChunk,
            expectedSurfaceID: "surface-verified-replay"
        ) == .legacy)

        let misroutedFrame = try frame(
            surfaceID: "another-surface",
            renderEpoch: "epoch",
            renderRevision: 2,
            stateSeq: 2,
            columns: 80,
            text: "misrouted frame"
        )
        let misroutedChunk = MobileTerminalOutputChunk(
            data: misroutedFrame.vtPatchBytes(),
            streamToken: token,
            sourceRenderGridFrame: misroutedFrame,
            requiresVerifiedReplay: true
        )
        #expect(terminalOutputApplicationPath(
            for: misroutedChunk,
            expectedSurfaceID: "surface-verified-replay"
        ) == .rejectUnverified)
    }

    private func commit(
        _ frame: MobileTerminalRenderGridFrame,
        to machine: VerifiedTerminalReplayStateMachine
    ) {
        guard case .apply(let transaction) = machine.begin(frame: frame) else {
            Issue.record("expected replay transaction")
            return
        }
        #expect(machine.complete(transactionID: transaction.id, observedFrame: frame) == .reveal)
    }

    private func extractTransaction(
        from decision: VerifiedTerminalReplayStateMachine.BeginDecision
    ) -> VerifiedTerminalReplayStateMachine.Transaction? {
        guard case .apply(let transaction) = decision else { return nil }
        return transaction
    }

    private func frame(
        surfaceID: String = "surface-verified-replay",
        renderEpoch: String = "epoch-default",
        renderRevision: UInt64,
        stateSeq: UInt64,
        columns: Int,
        text: String,
        styleID: Int = 1,
        full: Bool = true
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            columns: columns,
            rows: 3,
            cursor: .init(row: 1, column: min(4, columns - 1), style: .bar, blinking: true),
            full: full,
            styles: [
                .init(id: 0, foreground: "#FDFEF1", background: "#272822"),
                .init(
                    id: styleID,
                    foreground: "#A6E22E",
                    background: "#272822",
                    bold: true,
                    underline: true
                )
            ],
            rowSpans: [
                .init(row: 0, column: 0, styleID: styleID, text: text)
            ],
            activeScreen: .primary,
            modes: [
                .init(code: 1, on: true),
                .init(code: 7, on: true),
                .init(code: 2004, on: true)
            ]
        )
    }
}
