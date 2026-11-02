import AppKit
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// u3849 "add server UI is very bad": the Add Server sheet walks one explicit step at a time
/// (enter code, looking up, refused, review, approving, approve failed, added), every step has a
/// Return and an Escape answer that a click on the same button also runs, a stale result never
/// greets the next opening, and the code field takes the keyboard as the sheet opens.
@MainActor @Suite(.serialized, .closesItsWindows) struct AddServerFlowTests {
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

    private var returnButton: AddServerButton? { model.addServerButtons.first(where: \.isDefault) }
    private var escapeButton: AddServerButton? { model.addServerButtons.first(where: { !$0.isDefault }) }

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
        #expect(returnButton == AddServerButton(action: .retry, isDefault: true, enabled: true))
        let before = source.received.count
        #expect(model.perform(.retry) == false)
        #expect(source.received.count == before + 1)
        #expect(model.addServerStep == .approving(MockServerScenario.candidate))
    }

    // MARK: - Keys

    @Test func everyStepButAddedHasCancelOnEscape() throws {
        #expect(escapeButton == AddServerButton(action: .cancel, isDefault: false, enabled: true))
        model.setApprovalCode(MockServerScenario.offerCode)
        #expect(escapeButton?.action == .cancel)
        model.handle(.candidate(MockServerScenario.candidate))
        try settleLast(reject: nil)
        #expect(escapeButton?.action == .cancel)
        model.approve()
        #expect(escapeButton?.action == .cancel)
    }

    @Test func returnApprovesOnlyWhenTheServerIsFound() throws {
        #expect(returnButton == AddServerButton(action: .approve, isDefault: true, enabled: false))
        model.setApprovalCode(MockServerScenario.offerCode)
        #expect(returnButton?.enabled == false)
        model.handle(.candidate(MockServerScenario.candidate))
        try settleLast(reject: nil)
        #expect(returnButton == AddServerButton(action: .approve, isDefault: true, enabled: true))
        #expect(model.perform(.approve) == false)
        let approve = try #require(source.received.last)
        #expect(approve.kind == .approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build-01", placeChief: false))
        // In flight: Return is off, so a second press sends nothing.
        #expect(returnButton?.enabled == false)
        let sent = source.received.count
        _ = model.perform(.approve)
        #expect(source.received.count == sent)
    }

    @Test func addedHasOnlyDoneOnReturnAndDoneCloses() throws {
        try find()
        model.approve()
        try settleLast(reject: nil)
        #expect(model.addServerButtons == [AddServerButton(action: .done, isDefault: true, enabled: true)])
        #expect(model.perform(.done) == true)
    }

    @Test func cancelDropsTheDraftAndCloses() throws {
        try find()
        #expect(model.perform(.cancel) == true)
        #expect(model.approval == ServerApprovalDraft())
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

    @Test func theCodeFieldTakesTheKeyboardWhenTheSheetOpens() throws {
        let view = ServerHostView(model: model, surface: .approver, material: .opaque)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect((editor.delegate as? NSTextField) != nil)
    }
}
