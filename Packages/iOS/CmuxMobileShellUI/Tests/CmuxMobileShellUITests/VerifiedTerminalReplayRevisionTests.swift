import CMUXMobileCore
import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Foundation
import Testing

@MainActor
@Suite("Verified terminal replay revision identity")
struct VerifiedTerminalReplayRevisionTests {
    @Test("a request-only viewport floor does not mix content and emission counters")
    func requestOnlyViewportFloorDoesNotRejectFirstEmission() throws {
        let machine = VerifiedTerminalReplayStateMachine()
        let initial = try frame(
            renderRevision: 1, stateSeq: 1, columns: 80, text: "initial", emissionRevision: 1
        )
        commit(initial, to: machine)

        // A request-only observation advances the content floor without
        // claiming an emitted-frame identity.
        machine.acknowledgeViewport(
            renderEpoch: "epoch-default", renderRevisionFloor: 10
        )
        let firstLive = try frame(
            renderRevision: 10, stateSeq: 2, columns: 80, text: "observed", emissionRevision: 2
        )
        guard case .apply = machine.begin(frame: firstLive) else {
            Issue.record("a request-only content floor must not reject an independent emission revision")
            return
        }
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

    private func frame(
        renderEpoch: String = "epoch-default",
        renderRevision: UInt64,
        stateSeq: UInt64,
        columns: Int,
        text: String,
        emissionRevision: UInt64
    ) throws -> MobileTerminalRenderGridFrame {
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-verified-replay", stateSeq: stateSeq, renderEpoch: renderEpoch,
            renderRevision: renderRevision, columns: columns, rows: 3,
            cursor: .init(row: 1, column: min(4, columns - 1), style: .bar, blinking: true),
            styles: [
                .init(id: 0, foreground: "#FDFEF1", background: "#272822"),
                .init(id: 1, foreground: "#A6E22E", background: "#272822", bold: true, underline: true)
            ],
            rowSpans: [.init(row: 0, column: 0, styleID: 1, text: text)],
            activeScreen: .primary,
            modes: [.init(code: 1, on: true), .init(code: 7, on: true), .init(code: 2004, on: true)]
        )
        frame.emissionRevision = emissionRevision
        return frame
    }
}
