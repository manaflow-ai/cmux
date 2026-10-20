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

    @Test("a remount accepts a fresh full replay without admitting stale completion")
    func remountReactivatesReplayVerification() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let beforeUnmount = try frame(
            renderEpoch: "epoch-before-unmount",
            renderRevision: 1,
            stateSeq: 1,
            columns: 80,
            text: "before unmount"
        )
        let staleTransaction = try #require(
            extractTransaction(from: machine.begin(frame: beforeUnmount))
        )

        machine.invalidate()
        machine.prepareForMount()

        #expect(
            machine.complete(
                transactionID: staleTransaction.id,
                observedFrame: beforeUnmount
            ) == .ignoreStaleCompletion
        )

        let afterRemount = try frame(
            renderEpoch: "epoch-after-remount",
            renderRevision: 1,
            stateSeq: 2,
            columns: 80,
            text: "after remount"
        )
        let remountTransaction = try #require(
            extractTransaction(from: machine.begin(frame: afterRemount))
        )
        #expect(remountTransaction.id != staleTransaction.id)
        #expect(
            machine.complete(
                transactionID: remountTransaction.id,
                observedFrame: afterRemount
            ) == .reveal
        )
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "after remount")
        #expect(!machine.isFrozen)
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

    @Test("a replay sized by stale daemon state holds the last verified pixels and renegotiates")
    func staleGridReplayHoldsAndRenegotiates() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(lastGood, to: machine)
        let generation = machine.updateExpectedViewportDimensions(
            columns: 80,
            rows: 3,
            reportID: 1
        )

        let staleGrid = try frame(renderRevision: 2, stateSeq: 2, columns: 41, text: "stale grid")
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: staleGrid) else {
            Issue.record("a pre-acknowledgement mismatched grid must hold and renegotiate")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "last good")
        #expect(machine.isFrozen)

        // Later stale captures keep holding without re-sending the report.
        let nextStale = try frame(renderRevision: 3, stateSeq: 3, columns: 41, text: "still stale")
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: nextStale) else {
            Issue.record("subsequent stale-grid frames must hold without renegotiating again")
            return
        }

        // The acknowledgement answering the current report floors the stale
        // captures; the fresh frame at the settled grid verifies and reveals.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 3,
            reportID: 1,
            negotiationGeneration: generation,
            reportedColumns: 80,
            reportedRows: 3,
            grantedColumns: 80,
            grantedRows: 3
        )
        let settled = try frame(renderRevision: 4, stateSeq: 4, columns: 80, text: "settled grid")
        let transaction = try #require(extractTransaction(from: machine.begin(frame: settled)))
        #expect(machine.complete(transactionID: transaction.id, observedFrame: settled) == .reveal)
        #expect(machine.visibleSnapshot?.columns == 80)
        #expect(!machine.isFrozen)

        // Daemon state regressing AFTER the settlement (a reconnect that
        // reverted the shared PTY) contradicts both the capacity and the
        // settled grant: the hold re-arms with a fresh budget.
        let regressed = try frame(renderRevision: 5, stateSeq: 5, columns: 41, text: "regressed")
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: regressed) else {
            Issue.record("a post-settlement grid regression must hold and renegotiate")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "settled grid")
    }

    @Test("an acknowledged smaller grant applies letterboxed instead of holding")
    func acknowledgedSmallerGrantApplies() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(lastGood, to: machine)
        let generation = machine.updateExpectedViewportDimensions(
            columns: 80,
            rows: 3,
            reportID: 1
        )

        let staleGrid = try frame(renderRevision: 2, stateSeq: 2, columns: 41, text: "stale grid")
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: staleGrid) else {
            Issue.record("a pre-acknowledgement mismatched grid must hold and renegotiate")
            return
        }

        // The daemon answers the report but another viewer constrains the
        // shared PTY: the settled grant is genuinely smaller. Post-floor
        // frames at that grant verify normally (the surface letterboxes at
        // the user's font); holding here would freeze the terminal forever.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 2,
            reportID: 1,
            negotiationGeneration: generation,
            reportedColumns: 80,
            reportedRows: 3,
            grantedColumns: 41,
            grantedRows: 3
        )
        let constrained = try frame(
            renderRevision: 3,
            stateSeq: 3,
            columns: 41,
            text: "constrained grant"
        )
        let transaction = try #require(extractTransaction(from: machine.begin(frame: constrained)))
        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: constrained) == .reveal
        )
        #expect(machine.visibleSnapshot?.columns == 41)
    }

    @Test("a capacity change re-arms the hold despite an older acknowledgement")
    func capacityChangeSupersedesOlderAcknowledgement() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(lastGood, to: machine)
        let generation = machine.updateExpectedViewportDimensions(
            columns: 80,
            rows: 3,
            reportID: 1
        )
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 1,
            reportID: 1,
            negotiationGeneration: generation,
            reportedColumns: 80,
            reportedRows: 3,
            grantedColumns: 80,
            grantedRows: 3
        )

        // The viewport changes (rotation/keyboard): a new report goes out.
        // Frames still sized for the OLD negotiation must hold even though
        // the epoch has a recorded acknowledgement — that acknowledgement
        // answered the previous capacity, not this one.
        _ = machine.updateExpectedViewportDimensions(columns: 70, rows: 3, reportID: 2)
        let staleOldGrid = try frame(renderRevision: 2, stateSeq: 2, columns: 80, text: "old grid")
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: staleOldGrid) else {
            Issue.record("an acknowledgement for an older report must not bypass the hold")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "last good")

        // An out-of-order acknowledgement answering an OLDER report settles
        // nothing, even when its dimensions happen to match the current
        // capacity (a reassert can re-ask the same grid): only the newest
        // report's answer settles. Frames at the old grid keep holding.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 2,
            reportID: 1,
            negotiationGeneration: generation,
            reportedColumns: 70,
            reportedRows: 3,
            grantedColumns: 70,
            grantedRows: 3
        )
        let stillStale = try frame(renderRevision: 3, stateSeq: 3, columns: 80, text: "still old")
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: stillStale) else {
            Issue.record("an out-of-order acknowledgement must not settle the new negotiation")
            return
        }

        // The acknowledgement answering the CURRENT report settles it; the
        // fresh frame at the new grid verifies and reveals.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 3,
            reportID: 2,
            negotiationGeneration: generation,
            reportedColumns: 70,
            reportedRows: 3,
            grantedColumns: 70,
            grantedRows: 3
        )
        let settled = try frame(renderRevision: 4, stateSeq: 4, columns: 70, text: "new grid")
        let transaction = try #require(extractTransaction(from: machine.begin(frame: settled)))
        #expect(machine.complete(transactionID: transaction.id, observedFrame: settled) == .reveal)
        #expect(machine.visibleSnapshot?.columns == 70)
    }

    @Test("the stale-grid hold budget is bounded when no acknowledgement ever lands")
    func staleGridHoldBudgetIsBounded() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "last good")
        commit(lastGood, to: machine)
        _ = machine.updateExpectedViewportDimensions(columns: 80, rows: 3, reportID: 1)

        var revision: UInt64 = 2
        for held in 0..<VerifiedTerminalReplayStateMachine.maxRenegotiationHeldFrames {
            let stale = try frame(
                renderRevision: revision,
                stateSeq: revision,
                columns: 41,
                text: "stale \(revision)"
            )
            switch machine.begin(frame: stale) {
            case .renegotiateViewportAndKeepFrozen:
                #expect(held == 0, "only the first hold renegotiates")
            case .keepFrozenAndRequestReplay:
                #expect(held > 0, "the first hold must renegotiate")
            case .apply:
                Issue.record("frame \(held) must hold within the budget")
            }
            revision += 1
        }

        // The report was lost (no acknowledgement). Once the budget is
        // spent, the mismatched frame verifies and renders letterboxed
        // rather than freezing on the last verified pixels forever.
        let fallback = try frame(
            renderRevision: revision,
            stateSeq: revision,
            columns: 41,
            text: "fallback"
        )
        let transaction = try #require(extractTransaction(from: machine.begin(frame: fallback)))
        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: fallback) == .reveal
        )
        #expect(machine.visibleSnapshot?.columns == 41)
    }

    @Test("a mismatched grid never holds without last verified pixels")
    func mismatchedGridWithoutSnapshotApplies() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        _ = machine.updateExpectedViewportDimensions(columns: 80, rows: 3, reportID: 1)

        let coldMount = try frame(renderRevision: 1, stateSeq: 1, columns: 41, text: "cold mount")
        let transaction = try #require(extractTransaction(from: machine.begin(frame: coldMount)))
        #expect(
            machine.complete(transactionID: transaction.id, observedFrame: coldMount) == .reveal
        )
        #expect(machine.visibleSnapshot?.columns == 41)
    }

    @Test("a hold invalidates the settlement until the next acknowledgement")
    func holdInvalidatesSettlement() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 41, text: "constrained")
        commit(lastGood, to: machine)
        let generation = machine.updateExpectedViewportDimensions(
            columns: 80,
            rows: 3,
            reportID: 1
        )
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default",
            renderRevisionFloor: 1,
            reportID: 1,
            negotiationGeneration: generation,
            reportedColumns: 80,
            reportedRows: 3,
            grantedColumns: 41,
            grantedRows: 3
        )

        // A frame contradicting both the capacity and the settled grant
        // holds — and by holding, invalidates the settlement: the daemon
        // has proven it no longer renders the settled negotiation.
        let rogue = try frame(renderRevision: 2, stateSeq: 2, columns: 45, text: "rogue grid")
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: rogue) else {
            Issue.record("a contradicting frame must hold and renegotiate")
            return
        }

        // Frames at the SUPERSEDED grant no longer slide past the gate
        // while the fresh acknowledgement is in flight.
        let oldGrant = try frame(renderRevision: 3, stateSeq: 3, columns: 41, text: "old grant")
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: oldGrant) else {
            Issue.record("the superseded grant must renegotiate after a hold")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "constrained")
    }

    @Test("a retired-epoch frame is rejected before it can renegotiate")
    func retiredEpochFrameCannotRenegotiate() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let oldEpoch = try frame(
            renderEpoch: "epoch-before-reconnect",
            renderRevision: 5,
            stateSeq: 1,
            columns: 80,
            text: "old epoch"
        )
        commit(oldEpoch, to: machine)
        let newEpoch = try frame(
            renderEpoch: "epoch-after-reconnect",
            renderRevision: 1,
            stateSeq: 2,
            columns: 80,
            text: "new epoch"
        )
        commit(newEpoch, to: machine)
        _ = machine.updateExpectedViewportDimensions(columns: 80, rows: 3, reportID: 1)

        // A delayed mis-sized frame from the RETIRED epoch is plain stale:
        // it must be rejected without consuming hold budget or triggering a
        // renegotiation.
        let delayedRetired = try frame(
            renderEpoch: "epoch-before-reconnect",
            renderRevision: 6,
            stateSeq: 3,
            columns: 41,
            text: "retired stale"
        )
        guard case .keepFrozenAndRequestReplay = machine.begin(frame: delayedRetired) else {
            Issue.record("a retired-epoch frame must be rejected, not renegotiated")
            return
        }

        // The budget is untouched: a genuine stale-grid frame in the LIVE
        // epoch still gets the first-hold renegotiation decision.
        let liveStale = try frame(
            renderEpoch: "epoch-after-reconnect",
            renderRevision: 2,
            stateSeq: 4,
            columns: 41,
            text: "live stale"
        )
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: liveStale) else {
            Issue.record("the live epoch's first hold must still renegotiate")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "new epoch")
    }

    @Test("a delayed acknowledgement from a previous session settles nothing")
    func preResetAcknowledgementCannotSettle() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let lastGood = try frame(renderRevision: 1, stateSeq: 1, columns: 80, text: "old session")
        commit(lastGood, to: machine)
        let oldGeneration = machine.updateExpectedViewportDimensions(
            columns: 80,
            rows: 3,
            reportID: 7
        )

        // Remount: report IDs restart while the machine survives.
        machine.invalidate()
        machine.prepareForMount()
        let fresh = try frame(
            renderEpoch: "epoch-after-remount",
            renderRevision: 1,
            stateSeq: 2,
            columns: 80,
            text: "new session"
        )
        commit(fresh, to: machine)
        _ = machine.updateExpectedViewportDimensions(columns: 80, rows: 3, reportID: 1)

        // The old session's answer arrives late, with a report ID that
        // aliases past the new session's counter and dimensions that match
        // the current capacity. It must not settle the new negotiation.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-after-remount",
            renderRevisionFloor: 0,
            reportID: 7,
            negotiationGeneration: oldGeneration,
            reportedColumns: 80,
            reportedRows: 3,
            grantedColumns: 41,
            grantedRows: 3
        )
        let staleGrant = try frame(
            renderEpoch: "epoch-after-remount",
            renderRevision: 2,
            stateSeq: 3,
            columns: 41,
            text: "stale grant"
        )
        guard case .renegotiateViewportAndKeepFrozen = machine.begin(frame: staleGrant) else {
            Issue.record("a pre-reset acknowledgement must not whitelist stale-grid frames")
            return
        }
        #expect(machine.visibleSnapshot?.rows.first?.first?.text == "new session")
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
