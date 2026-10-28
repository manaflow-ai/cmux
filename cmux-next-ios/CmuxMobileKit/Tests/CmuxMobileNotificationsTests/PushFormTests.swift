import Foundation
import Testing
@testable import CmuxMobileNotifications

/// The content extension's option rows, Submit and composer (verify/rich-push.md).
@Suite struct PushFormTests {
    func question(_ questions: [PushQuestion]) -> PushPayload {
        PushPayload(mac: "mac-1", macName: "Mac mini", kind: .question, sessionId: "s-1", permissionId: "perm-1", questions: questions)
    }

    let branch = PushQuestion(question: "Which branch?", options: [.init(label: "main"), .init(label: "dev")])

    @Test func singleChoiceSendsOnTap() {
        var form = PushForm(payload: question([branch]))
        #expect(form.sendsOnTap)
        #expect(form.rows.map(\.style) == [.choice, .choice])
        #expect(form.tap(form.rows[1]) == .option(1, label: "dev"))
        #expect(!form.showsSubmit)
    }

    @Test func multiSelectTogglesThenSubmitsInOptionOrder() {
        let q = PushQuestion(question: "Which?", multiSelect: true, options: [.init(label: "a"), .init(label: "b"), .init(label: "c")])
        var form = PushForm(payload: question([q]))
        #expect(form.rows.map(\.style) == [.checkbox, .checkbox, .checkbox])
        #expect(form.showsSubmit && !form.canSubmit)
        #expect(form.tap(form.rows[2]) == nil)
        #expect(form.tap(form.rows[0]) == nil)
        #expect(form.tap(form.rows[1]) == nil)
        #expect(form.tap(form.rows[1]) == nil) // unchecks b
        #expect(form.isSelected(form.rows[0]) && !form.isSelected(form.rows[1]))
        #expect(form.answers == .answers(selected: [["a", "c"]], other: [""]))
    }

    @Test func severalQuestionsNeedEveryAnswerAndKeepOneChoiceEach() {
        let other = PushQuestion(question: "Name?", allowsOther: true, options: [.init(label: "x")])
        var form = PushForm(payload: question([branch, other]))
        #expect(!form.sendsOnTap && form.showsSubmit)
        #expect(form.rows.map(\.style).allSatisfy { $0 == .checkbox })
        _ = form.tap(form.rows[0]) // main
        _ = form.tap(form.rows[1]) // dev replaces main (single choice)
        #expect(!form.canSubmit)
        form.other[1] = "  mine "
        #expect(form.answers == .answers(selected: [["dev"], []], other: ["", "mine"]))
        #expect(!form.hasComposer)
    }

    @Test func freeTextComposerAnswersTheQuestion() {
        let q = PushQuestion(question: "Which?", allowsOther: true, options: [.init(label: "a")])
        let form = PushForm(payload: question([q]))
        #expect(form.hasComposer && form.showsSubmit)
        #expect(form.composerReply("  other  ", attachments: []) == .answers(selected: [[]], other: ["other"]))
        #expect(form.composerReply(" ", attachments: []) == nil)
    }

    @Test func permissionRowsAreAllowAndDenyOptions() {
        var payload = PushPayload(mac: "mac-1", kind: .permission, permissionId: "p")
        payload.options = [PushOption(id: "a1", label: "Allow once", kind: .allowOnce),
                           PushOption(id: "a2", label: "Always allow", kind: .allowAlways),
                           PushOption(id: "x", label: "Weird", kind: nil),
                           PushOption(id: "r1", label: "Deny", kind: .rejectOnce)]
        var form = PushForm(payload: payload)
        // No Always allow row: acpmux refuses a lasting grant from a phone.
        #expect(form.rows.map(\.style) == [.allow, .deny])
        #expect(form.tap(form.rows[0]) == .allow(optionID: "a1"))
        #expect(form.tap(form.rows[1]) == .deny(optionID: "r1"))
        #expect(!form.hasComposer && !form.showsSubmit)
    }

    @Test func replyComposerCarriesTextAndAttachments() {
        let form = PushForm(payload: PushPayload(mac: "mac-1", kind: .completed, sessionId: "s"))
        #expect(form.rows.isEmpty && form.hasComposer)
        #expect(form.composerReply("", attachments: ["p.jpg"]) == .text("", attachments: ["p.jpg"]))
        #expect(form.composerReply("go on", attachments: []) == .text("go on", attachments: []))
        #expect(form.composerReply("", attachments: []) == nil)
    }

    @Test func previewsOffShowsContentOnlyUnlocked() {
        #expect(PushForm.showsContent(previews: true, unlocked: false))
        #expect(!PushForm.showsContent(previews: false, unlocked: false))
        #expect(PushForm.showsContent(previews: false, unlocked: true))
    }

    @Test func markerIsReadableWhereItCanBeWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PushProtectedMarker(directory: dir).isUnlocked())
        #expect(!PushProtectedMarker(directory: dir.appendingPathComponent("missing")).isUnlocked())
    }
}
