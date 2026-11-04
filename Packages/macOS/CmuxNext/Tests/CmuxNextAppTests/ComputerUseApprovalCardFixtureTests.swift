// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import Testing
@testable import CmuxNextComputerUse
@testable import CmuxNextMacScreen

/// DEBUG `debug.computer_use_card`: the real approval card with a fixture question, for
/// captures. It is on no worker link and no broker: whatever the card's buttons or a
/// dismissal do, nothing is decided, saved or sent to a worker.
@MainActor
struct ComputerUseApprovalCardFixtureTests {
    @Test func theFixtureAsksForClaudeInApiServerToUseSafari() {
        let request = ComputerUseApprovalCards.fixtureRequest(client: ComputerUseApprovalTests.client, nowMs: ComputerUseApprovalTests.nowMs)
        #expect(request.agent == "Claude")
        #expect(request.workspace == "api-server")
        #expect(request.target == ComputerUseApprovalApp(bundleID: "com.apple.Safari", executable: nil, name: "Safari"))
        #expect(request.client == ComputerUseApprovalTests.client)
        #expect(request.isAnswerable(nowMs: ComputerUseApprovalTests.nowMs))
        // The same card a worker's question gets.
        #expect(ComputerUseApprovalCards.spec(for: request, icon: nil).identifier == ComputerUseApprovalService.approvalDialogIdentifier)
    }

    @Test(.timeLimit(.minutes(1))) func everyPressOnTheFixtureCardOnlyClosesIt() async throws {
        let file = ComputerUseApprovalTests.temporaryFile()
        let store = ComputerUseApprovalStore(file: file)
        await store.load()
        let cards = ComputerUseApprovalCards(panels: false)
        let broker = ComputerUseApprovalBroker(store: store, nowMs: { ComputerUseApprovalTests.nowMs })
        broker.presenter = cards
        let (lines, sink) = AsyncStream<Data>.makeStream()
        _ = broker.attach(sink)

        for decision in ComputerUseApprovalDecision.allCases {
            let request = ComputerUseApprovalCards.fixtureRequest(client: ComputerUseApprovalTests.client, nowMs: ComputerUseApprovalTests.nowMs)
            let id = cards.showFixture(request)
            let dialog = try #require(cards.dialogID(id), "\(decision)")
            #expect(cards.center.press(dialog, button: decision.rawValue), "\(decision)")
            #expect(cards.dialogID(id) == nil, "\(decision)")
            #expect(broker.pending.isEmpty, "\(decision)")
        }
        // A dismissal of the fixture closes it the same way.
        let shown = cards.showFixture(ComputerUseApprovalCards.fixtureRequest(client: ComputerUseApprovalTests.client,
                                                                               nowMs: ComputerUseApprovalTests.nowMs))
        #expect(cards.dialogID(shown) != nil)
        #expect(cards.dismissFixtures() == 1)
        #expect(cards.dialogID(shown) == nil)
        #expect(cards.dismissFixtures() == 0)

        await store.flush()
        #expect(store.apps.isEmpty)
        #expect(await ComputerUseApprovalTests.read(file).isEmpty)
        #expect(broker.pending.isEmpty)
        // The link heard only the saved list it hears on attach: no answer, no list change, no revoke.
        sink.finish()
        var types: [String] = []
        for await line in lines { types.append(try ComputerUseApprovalTests.json(line)["type"] as? String ?? "?") }
        #expect(types == ["approved_apps"])
    }
}
#endif
