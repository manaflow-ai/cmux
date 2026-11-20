import AppKit
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// u3849 "add server UI is very bad": the Add Server card walks one explicit step at a time
/// (enter code, looking up, refused, review, approving, approve failed, added), and a stale result
/// never greets the next opening. The card's buttons and keys follow from the step in the page
/// (webviews/src/pages/server-cards/server/model.test.ts).
@MainActor @Suite(.serialized) struct AddServerFlowTests {
    let source: MockServerSource
    let model: ServerModel

    init() {
        _ = NSApplication.shared
        source = MockServerSource(scenario: .healthyMac)
        source.echoImmediately = false
        model = ServerModel(source: source)
        model.start()
    }

    private func settleLast(reject: String?) throws {
        let key = try #require(model.pending.last?.key)
        model.handle(.settled(key: key, reject: reject))
    }

    private func find() throws {
        model.setApprovalCode(MockServerScenario.offerCode)
        model.handle(.candidate(MockServerScenario.candidate))
        try settleLast(reject: nil)
    }

    // MARK: - Steps

    @Test func stepsFollowTheCodeTheLookupAndTheApprove() throws {
        #expect(model.addServerStep == .enterCode)
        model.setApprovalCode("7KQ4")
        #expect(model.addServerStep == .enterCode)
        model.setApprovalCode(MockServerScenario.offerCode)
        #expect(model.addServerStep == .lookingUp)
        model.handle(.candidate(MockServerScenario.candidate))
        try settleLast(reject: nil)
        #expect(model.addServerStep == .review(MockServerScenario.candidate))
        model.approve()
        #expect(model.addServerStep == .approving(MockServerScenario.candidate))
        try settleLast(reject: nil)
        #expect(model.addServerStep == .added(MockServerScenario.candidate.name))
    }

    @Test func aRefusedCodeIsItsOwnStepAndTypingClearsIt() throws {
        model.setApprovalCode("ZZZZZZZZ")
        try settleLast(reject: "No server is waiting with that code.")
        #expect(model.addServerStep == .codeRefused("No server is waiting with that code."))
        model.setApprovalCode("ZZZZ-ZZZ")
        #expect(model.addServerStep == .enterCode)
        #expect(model.lastReject == nil)
    }

    @Test func aRefusedApproveKeepsTheServerAndReturnTriesAgain() throws {
        try find()
        model.approve()
        try settleLast(reject: "Could not reach cmux.")
        #expect(model.addServerStep == .approveFailed(MockServerScenario.candidate, "Could not reach cmux."))
        #expect(model.canApprove)
        let before = source.received.count
        model.approve()
        #expect(source.received.count == before + 1)
        #expect(model.addServerStep == .approving(MockServerScenario.candidate))
    }

    // MARK: - Approve

    @Test func approveGoesOnlyWhenTheServerIsFoundAndOnce() throws {
        #expect(!model.canApprove)
        model.setApprovalCode(MockServerScenario.offerCode)
        #expect(!model.canApprove)
        model.handle(.candidate(MockServerScenario.candidate))
        try settleLast(reject: nil)
        #expect(model.canApprove)
        model.approve()
        let approve = try #require(source.received.last)
        #expect(approve.kind == .approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build-01", placeChief: false))
        // In flight: a second approve sends nothing.
        #expect(!model.canApprove)
        let sent = source.received.count
        model.approve()
        #expect(source.received.count == sent)
    }

    @Test func cancelDropsTheDraftAndTheLastAnswer() throws {
        try find()
        model.dismissApproval()
        #expect(model.approval == ServerApprovalDraft())
        #expect(model.addServerStep == .enterCode)
    }

    /// The menu bar item hidden and shown again with a lookup in flight: that lookup's refusal is
    /// the stopped session's and never shows on the new one.
    @Test func aRefusalForAnIntentNoLongerPendingIsIgnored() throws {
        model.setApprovalCode(MockServerScenario.offerCode)
        let key = try #require(model.pending.last?.key)
        model.stop()
        model.start()
        model.handle(.settled(key: key, reject: "Could not reach cmux."))
        #expect(model.lastReject == nil)
        #expect(model.addServerStep == .enterCode)
    }

    // MARK: - Opening

    @Test func reopeningAfterAnAddStartsClean() throws {
        try find()
        model.approve()
        try settleLast(reject: nil)
        model.beginApproval()
        #expect(model.addServerStep == .enterCode)
        #expect(model.lastApproved == nil)
    }

    @Test func reopeningWithATypedCodeLooksItUpAgain() throws {
        model.setApprovalCode("ZZZZZZZZ")
        try settleLast(reject: "No server is waiting with that code.")
        let sent = source.received.count
        model.beginApproval()
        #expect(source.received.count == sent + 1)
        #expect(model.addServerStep == .lookingUp)
    }
}
