import AppKit
@testable import CmuxNextFloating
import Foundation
import Testing

/// The pet's reply box: a click on the pet opens it on the newest notice (else the Chief), in the
/// bubble's place, taking the keys without activating cmux. Return sends typed text to the Chief or
/// into a terminal and closes it once sent; a failed send keeps the text; a notice that takes no
/// typed reply (an agent chat) opens instead; ⌘Return opens the target.
@MainActor @Suite(.serialized) struct ChiefPetReplyTests {
    static func notice(_ id: UInt64, tab: String, reply: ChiefPetNotice.Reply) -> ChiefPetNotice {
        ChiefPetNotice(id: id, tab: tab, surface: nil, title: "Claude \(tab)", detail: "", kind: .needsYou, reply: reply)
    }

    @Test func targetsAreTheNoticesThenTheChief() {
        var feed = ChiefPetFeed()
        #expect(ChiefPetReply.targets(feed) == [.chief])
        let terminal = Self.notice(1, tab: "a", reply: .type)
        let chat = Self.notice(2, tab: "b", reply: .openChat)
        feed.arrive(terminal)
        feed.arrive(chat)
        #expect(ChiefPetReply.targets(feed) == [.notice(chat), .notice(terminal), .chief])
    }

    @Test func returnSendsOrOpens() {
        let terminal = ChiefPetReplyTarget.notice(Self.notice(1, tab: "a", reply: .type))
        let chat = ChiefPetReplyTarget.notice(Self.notice(2, tab: "b", reply: .openChat))
        #expect(ChiefPetReply.submit(.chief, text: "  ship it \n", command: false) == .send(.chief, "ship it"))
        #expect(ChiefPetReply.submit(terminal, text: "yes", command: false) == .send(terminal, "yes"))
        #expect(ChiefPetReply.submit(terminal, text: "   ", command: false) == .nothing)
        #expect(ChiefPetReply.submit(chat, text: "hello", command: false) == .open(chat), "an agent chat is answered in the chat")
        #expect(ChiefPetReply.submit(.chief, text: "hi", command: true) == .open(.chief))
    }

    @Test func twoNoticesWithOneTitleStayTwoTargets() {
        let panel = ChiefPetReplyPanel()
        let a = Self.notice(1, tab: "a", reply: .type), b = ChiefPetNotice(id: 2, tab: "b", surface: nil, title: a.title, detail: "", kind: .needsYou, reply: .type)
        panel.show(targets: [.notice(a), .notice(b), .chief])
        #expect(panel.picker.numberOfItems == 3)
        panel.picker.selectItem(at: 2)
        #expect(panel.target == .chief, "the menu index still lines up with the targets")
    }

    @Test func aChosenSessionThatLeavesFallsBackToTheChiefNotAnotherSession() {
        let panel = ChiefPetReplyPanel()
        let a = Self.notice(1, tab: "a", reply: .type), b = Self.notice(2, tab: "b", reply: .type)
        panel.show(targets: [.notice(a), .notice(b), .chief])
        panel.picker.selectItem(at: 1)
        // b's tab got a newer notice: still b.
        let b2 = Self.notice(3, tab: "b", reply: .type)
        panel.show(targets: [.notice(b2), .notice(a), .chief])
        #expect(panel.target == .notice(b2))
        // b's tab was read: the Chief, never a.
        panel.show(targets: [.notice(a), .chief])
        #expect(panel.target == .chief)
    }

    /// The placeholder that names the target hides once there is text, so a session's answer typed
    /// before its notice left must not quietly go to the Chief instead: the text goes with it.
    @Test func typedTextLeavesWithItsSession() {
        let panel = ChiefPetReplyPanel()
        let a = Self.notice(1, tab: "a", reply: .type)
        panel.show(targets: [.notice(a), .chief])
        panel.field.stringValue = "y"
        panel.show(targets: [.chief])
        #expect(panel.target == .chief)
        #expect(panel.field.stringValue.isEmpty)
        panel.field.stringValue = "status?"
        panel.show(targets: [.notice(a), .chief])
        #expect(panel.target == .chief, "the Chief stays chosen")
        #expect(panel.field.stringValue == "status?", "text for a target that stayed is kept")
    }

    @Test func placeholderNamesWhereItGoes() {
        #expect(ChiefPetReply.placeholder(.chief) == "Message Chief")
        #expect(ChiefPetReply.placeholder(.notice(Self.notice(1, tab: "a", reply: .type))) == "Reply to Claude a")
        #expect(ChiefPetReply.placeholder(.notice(Self.notice(2, tab: "b", reply: .openChat))) == "Return opens Claude b")
    }

    final class Recorder {
        var opened: [ChiefPetReplyTarget] = []
        var sent: [(ChiefPetReplyTarget, String)] = []
        var succeeds = true
    }

    static func controller(_ recorder: Recorder) -> ChiefPetController {
        let name = "ChiefPetReplyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                  actions: ChiefPetActions(open: { recorder.opened.append($0) }, send: { target, text in
                                      recorder.sent.append((target, text))
                                      return recorder.succeeds
                                  }))
    }

    @Test func clickOpensTheBoxOnTheNewestNoticeInTheBubblesPlace() throws {
        let recorder = Recorder()
        let controller = Self.controller(recorder)
        defer { controller.sync(false) }
        controller.sync(true)
        let terminal = Self.notice(1, tab: "a", reply: .type)
        controller.arrive(terminal)
        #expect(controller.bubble?.isVisible == true)
        controller.panel?.onClick?()
        let reply = try #require(controller.replyPanel)
        #expect(reply.isVisible)
        #expect(reply.styleMask.contains(.nonactivatingPanel))
        #expect(reply.canBecomeKey)
        #expect(reply.target == .notice(terminal))
        #expect(controller.bubble?.isVisible == false, "the box sits where the bubble was")
        controller.panel?.onClick?()
        #expect(!reply.isVisible, "a second click puts it away")
        #expect(controller.bubble?.isVisible == true)
    }

    @Test func sentReplyClosesTheBoxAndFailedOneKeepsTheText() async throws {
        let recorder = Recorder()
        let controller = Self.controller(recorder)
        defer { controller.sync(false) }
        controller.sync(true)
        controller.panel?.onClick?()
        let reply = try #require(controller.replyPanel)
        recorder.succeeds = false
        reply.field.stringValue = "status?"
        controller.submit(.chief, text: reply.field.stringValue, command: false)
        for _ in 0..<1000 where controller.sending { await Task.yield() }
        #expect(recorder.sent.map(\.1) == ["status?"])
        #expect(reply.isVisible)
        #expect(reply.field.stringValue == "status?")
        recorder.succeeds = true
        controller.submit(.chief, text: reply.field.stringValue, command: false)
        for _ in 0..<1000 where controller.sending || reply.isVisible { await Task.yield() }
        #expect(recorder.sent.count == 2)
        #expect(!reply.isVisible)
        #expect(reply.field.stringValue.isEmpty)
    }

    @Test func agentChatAndCommandReturnOpenInsteadOfSending() throws {
        let recorder = Recorder()
        let controller = Self.controller(recorder)
        defer { controller.sync(false) }
        controller.sync(true)
        let chat = ChiefPetReplyTarget.notice(Self.notice(2, tab: "b", reply: .openChat))
        controller.panel?.onClick?()
        controller.submit(chat, text: "hello", command: false)
        controller.panel?.onClick?()
        controller.submit(.chief, text: "", command: true)
        #expect(recorder.opened == [chat, .chief])
        #expect(recorder.sent.isEmpty)
        #expect(controller.replyPanel?.isVisible == false)
    }
}
