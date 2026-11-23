import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import Foundation
import Testing

/// The native Add Server card (``AddServerDialog``): words and a way out in every step, typing never redraws it,
/// and only the person's own click on Approve adds the found server (never Return, a press of its button or a
/// script).
@MainActor @Suite(.serialized) struct AddServerDialogTests {
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func approvals(_ source: MockServerSource) -> [ServerIntentKind] {
        source.received.map(\.kind).filter { if case .approveCode = $0 { true } else { false } }
    }

    private func open(_ source: MockServerSource = MockServerSource(scenario: .unpaired)) -> AddServerDialog {
        _ = NSApplication.shared
        let model = ServerModel(source: source)
        model.start()
        model.beginApproval()
        let dialog = AddServerDialog(model: model)
        dialog.open(over: nil, takeKeys: false)
        return dialog
    }

    /// Every step of the card has words and a way out: never an empty glass shell, and Escape or a button always
    /// closes it (Lawrence 2026-11-17).
    @Test func everyStepHasWordsAndAWayOut() async throws {
        let source = MockServerSource(scenario: .unpaired)
        source.echoImmediately = false
        let dialog = open(source)
        defer { dialog.close() }
        func check(_ label: String) throws {
            let card = try #require(dialog.panel.dialogView, "\(label): the card shows")
            #expect(CmuxFloatingDialogPanel.hasContent(card.spec), "\(label): words on the first frame")
            #expect(card.spec.cancelButton != nil || card.spec.defaultButton != nil, "\(label): Escape or Return closes it")
            #expect(dialog.panel.isVisible)
        }
        try check("enter code")
        dialog.model.setApprovalCode("7KQ4M2XD")
        await settle()
        try check("looking up")
        source.deliverHeld()
        await settle()
        try check("review")
        #expect(dialog.panel.dialogView?.spec.cancelButton?.title == AddServerStrings.deny, "Cancel reads Deny once a server shows")
        dialog.model.setApprovalCode("ZZZZZZZZ")
        source.deliverHeld()
        await settle()
        try check("code refused")
    }

    /// The card's shape leaves out what the person types: a keystroke never rebuilds the card (its field keeps the
    /// caret and the keys).
    @Test func typingNeverRedrawsTheCard() async throws {
        let dialog = open()
        defer { dialog.close() }
        let card = try #require(dialog.panel.dialogView)
        card.dialog.edited(["code": .text("7KQ")])
        await settle()
        #expect(dialog.model.approval.code == "7KQ")
        #expect(dialog.panel.dialogView === card, "the same card while the code is incomplete")
    }

    /// SECURITY: Approve from Return or a press of its button (Accessibility, a script) adds nothing: only the
    /// person's own click, which the panel reads from its dispatch (``CmuxDialogPersonClick``), adds the server.
    @Test func approveTakesOnlyThePersonsClick() async throws {
        let source = MockServerSource(scenario: .unpaired)
        let dialog = open(source)
        defer { dialog.close() }
        try #require(dialog.panel.dialogView).dialog.edited(["code": .text("7kq4m2xd")])
        await settle()
        guard case .review = dialog.model.addServerStep else { Issue.record("the code finds the server: \(dialog.model.addServerStep)"); return }
        let card = try #require(dialog.panel.dialogView)
        let approve = try #require(card.spec.buttons.first { $0.id == AddServerCard.ID.approve })
        #expect(approve.personOnly, "Approve is click only")
        #expect(card.spec.defaultButton == nil, "Return presses nothing")
        card.dialog.handle(.return, modifiers: [])
        card.dialog.press(AddServerCard.ID.approve)
        #expect(approvals(source).isEmpty, "no key and no programmatic press approves")
        card.dialog.edited(["team": .text("team_other")])
        #expect(dialog.model.approval.team == "team_personal", "a team the server does not offer is refused")
        card.dialog.edited(["team": .text("team_manaflow"), "name": .text(" box ")])
        dialog.panel.onPersonPress?(AddServerCard.ID.approve)
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_manaflow", name: "box",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)], "the person's click approves, with the name trimmed")
        dialog.panel.onPersonPress?(AddServerCard.ID.approve)
        #expect(approvals(source).count == 1, "a second click while it adds sends nothing")
    }

    @Test func cancelDropsTheDraftAndEscapeCloses() async throws {
        let dialog = open()
        try #require(dialog.panel.dialogView).dialog.edited(["code": .text("7KQ4")])
        try #require(dialog.panel.dialogView).dialog.handle(.escape, modifiers: [])
        #expect(!dialog.panel.isVisible, "Escape closes it")
        #expect(dialog.model.approval == ServerApprovalDraft(), "its Cancel drops the draft")
    }

    /// The card closed from outside (Stop Serving) with a found server: reopened, the typed code stays and is
    /// looked up again, never showing the old facts.
    @Test func reopeningAfterAnOutsideCloseLooksTheCodeUpAgain() async throws {
        let source = MockServerSource(scenario: .unpaired)
        source.echoImmediately = false
        let dialog = open(source)
        defer { dialog.close() }
        dialog.model.setApprovalCode(MockServerScenario.offerCode)
        source.deliverHeld()
        #expect(dialog.model.addServerStep == .review(MockServerScenario.candidate))
        let sent = source.received.count
        dialog.close()
        dialog.model.beginApproval()
        dialog.open(over: nil, takeKeys: true)
        #expect(source.received.count == sent + 1)
        #expect(source.received.last?.kind == .lookupCode(MockServerScenario.offerCode))
        #expect(dialog.model.addServerStep == .lookingUp)
        #expect(dialog.model.approval.code == "7KQ4-M2XD")
    }
}
