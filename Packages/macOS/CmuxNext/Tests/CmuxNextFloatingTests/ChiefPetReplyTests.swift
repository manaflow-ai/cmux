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

/// Show in Mini (Leo 2026-11-07: "we want to keep typing to that, like, persistent session"): the
/// mini stands for a picked chat, kept across launches; its reply box talks to that chat, shows the
/// chat's newest reply under the field and stays open after a send.
@MainActor @Suite(.serialized) struct ChiefPetShowInMiniTests {
    static let chat = ChiefPetSubject.Chat(host: "install:mac", session: "s-coord")
    static let home = ChiefPetHome(chat: chat, title: "Coordinator", latest: "Merged #123; next is the gallery.")

    static func defaults() -> UserDefaults {
        let name = "ChiefPetShowInMiniTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func thePickedChatIsKeptAndTheChiefIsTheDefault() {
        let defaults = Self.defaults()
        let subject = ChiefPetSubject(defaults: defaults)
        #expect(subject.chat == nil, "the Chief by default")
        subject.show(Self.chat)
        #expect(ChiefPetSubject(defaults: defaults).chat == Self.chat, "kept across launches")
        #expect(subject.shows(session: "s-coord"))
        subject.show(nil)
        #expect(ChiefPetSubject(defaults: defaults).chat == nil)
    }

    @Test func theMinisChatTakesTheChiefsPlaceInTheTargets() {
        var feed = ChiefPetFeed()
        let target = ChiefPetReplyTarget.chat(Self.chat, title: "Coordinator")
        #expect(ChiefPetReply.targets(feed, home: target) == [target])
        let notice = ChiefPetReplyTests.notice(1, tab: "a", reply: .type)
        feed.arrive(notice)
        #expect(ChiefPetReply.targets(feed, home: target) == [.notice(notice), target])
        #expect(ChiefPetReply.submit(target, text: " status? ", command: false) == .send(target, "status?"), "typed text goes to the chat")
        #expect(ChiefPetReply.placeholder(target) == "Message Coordinator")
        #expect(ChiefPetReply.sameTarget(target, .chat(Self.chat, title: "Renamed")), "a new title is the same chat")
        #expect(!ChiefPetReply.sameTarget(target, .chief))
    }

    @Test func theBoxShowsTheChatsNewestReplyOnlyWhileItIsChosen() {
        let panel = ChiefPetReplyPanel()
        let target = ChiefPetReplyTarget.chat(Self.chat, title: "Coordinator")
        let notice = ChiefPetReplyTests.notice(1, tab: "a", reply: .type)
        panel.show(targets: [.notice(notice), target])
        panel.show(latest: Self.home.latest, of: target)
        #expect(panel.latestLabel.isHidden, "a notice is chosen: its reply line is not the chat's")
        #expect(panel.preferredHeight == ChiefPetReplyPanel.size.height)
        panel.picker.selectItem(at: 1)
        panel.picker.sendAction(panel.picker.action, to: panel.picker.target)
        #expect(!panel.latestLabel.isHidden)
        #expect(panel.latestLabel.stringValue == Self.home.latest)
        #expect(panel.preferredHeight > ChiefPetReplyPanel.size.height, "the box grows for the reply")
        panel.show(latest: nil, of: target)
        #expect(panel.latestLabel.isHidden)
    }

    @Test func sendingToTheChatKeepsTheBoxOpenAndNamesThePet() async throws {
        let recorder = ChiefPetReplyTests.Recorder()
        let controller = ChiefPetReplyTests.controller(recorder)
        defer { controller.sync(false) }
        controller.sync(true)
        controller.setHome(Self.home)
        controller.panel?.onClick?()
        let reply = try #require(controller.replyPanel)
        let target = ChiefPetReplyTarget.chat(Self.chat, title: "Coordinator")
        #expect(reply.target == target, "no notices: the box starts on the mini's chat")
        #expect(reply.latestLabel.stringValue == Self.home.latest)
        reply.field.stringValue = "ship it"
        controller.submit(target, text: reply.field.stringValue, command: false)
        for _ in 0..<1000 where controller.sending { await Task.yield() }
        #expect(recorder.sent.map(\.1) == ["ship it"])
        #expect(recorder.sent.first?.0 == target)
        #expect(reply.isVisible, "the box stays for the reply and the next message")
        #expect(reply.field.stringValue.isEmpty)
        // A newer reply arrives while the box is open.
        controller.setHome(ChiefPetHome(chat: Self.chat, title: "Coordinator", latest: "On it."))
        #expect(reply.latestLabel.stringValue == "On it.")
        // The chevron with no notices opens the chat, not the Chief.
        controller.panel?.onExpand?()
        #expect(recorder.opened.last == target)
    }
}
