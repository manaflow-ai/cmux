import CMUXMobileCore
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
        renderRevision: UInt64,
        stateSeq: UInt64,
        columns: Int,
        text: String,
        styleID: Int = 1
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "surface-verified-replay",
            stateSeq: stateSeq,
            renderRevision: renderRevision,
            columns: columns,
            rows: 3,
            cursor: .init(row: 1, column: min(4, columns - 1), style: .bar, blinking: true),
            styles: [
                .init(id: 0, foreground: "#FDFEF1", background: "#272822"),
                .init(
                    id: styleID,
                    foreground: "#A6E22E",
                    background: "#272822",
                    bold: true,
                    underline: true
                ),
            ],
            rowSpans: [
                .init(row: 0, column: 0, styleID: styleID, text: text),
            ],
            activeScreen: .primary,
            modes: [
                .init(code: 1, on: true),
                .init(code: 7, on: true),
                .init(code: 2004, on: true),
            ]
        )
    }
}
