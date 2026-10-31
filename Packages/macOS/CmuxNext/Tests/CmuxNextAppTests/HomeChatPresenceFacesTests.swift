import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// Leo 2026-10-26: "also chief chats we need multiplayer". Who else has the Chief chat open shows
/// as faces beside the header's name pill, from the owner's presence, never with this user's own.
@MainActor @Suite(.closesItsWindows, .serialized) struct HomeChatPresenceFacesTests {
    let conv = ConversationID("conv_faces")
    let me = ParticipantID("user_me")

    @Test func othersAreNamedFromTheConversationInNameOrderWithoutMe() {
        let people = [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: ParticipantID("user_sam"), kind: .human, displayName: "Sam Okafor"),
            CmuxHomeCore.Participant(id: ParticipantID("user_ana"), kind: .human, displayName: " Ana Ruiz "),
            CmuxHomeCore.Participant(id: ParticipantID("user_blank"), kind: .human, displayName: "  "),
        ]
        let viewing = Set(["user_sam", "user_ana", "user_blank", "user_gone"].map { ParticipantID($0) }).union([me])
        let names = HomeNativeTranscriptView.others(viewing: viewing, participants: people, me: me)
        #expect(names == ["Ana Ruiz", "Sam Okafor", "user_blank", "user_gone"], "a blank or missing name falls back to the id")
        #expect(HomeNativeTranscriptView.others(viewing: [me], participants: people, me: me).isEmpty)
    }

    @Test func theHeaderDrawsWhoElseHasTheChatOpenAndClearsWhenTheyLeave() async {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, nil)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        home.handle(.connection(.online))
        let view = HomeNativeTranscriptView(store: home, conversation: conv, me: me)
        defer { view.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        let host = view.transcript.controller.host
        host.paneHeader.title = "Chief"
        container.layoutSubtreeIfNeeded()
        #expect(view.debugHeaderFaces.initials.isEmpty)

        home.handle(.presence(conv, viewing: [me, ParticipantID("ana"), ParticipantID("sam")]))
        let drawn = await faces(of: view) { !$0.isEmpty }
        #expect(drawn.initials == ["A", "S"], "my own face is never drawn")
        #expect(drawn.shown, "the faces sit beside the shown name pill")
        #expect(drawn.label == HomeStrings.alsoHere(["ana", "sam"].formatted(.list(type: .and))), "VoiceOver reads who is here")

        home.handle(.presence(conv, viewing: [me]))
        let left = await faces(of: view) { $0.isEmpty }
        #expect(left.initials.isEmpty)
        #expect(!left.shown)
    }

    @Test func aTeammateTheChiefChatDoesNotListIsNamedFromAnotherConversation() async {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, nil)
        let mine = CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me")
        let chief = CmuxHomeCore.Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief")
        let ana = CmuxHomeCore.Participant(id: ParticipantID("user_ana"), kind: .human, displayName: "Ana Ruiz")
        func summary(_ id: ConversationID, _ people: [CmuxHomeCore.Participant]) -> ConversationSummary {
            ConversationSummary(id: id, participants: people, lastSeq: 0, rev: 1,
                                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        home.handle(.connection(.online))
        home.handle(.inbox(InboxSnapshot(me: mine, conversations: [
            summary(conv, [mine, chief]), summary(ConversationID("conv_team"), [mine, ana]),
        ], rev: 1)))
        let view = HomeNativeTranscriptView(store: home, conversation: conv, me: me)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        view.transcript.controller.host.paneHeader.title = "Chief"
        view.layoutSubtreeIfNeeded()

        home.handle(.presence(conv, viewing: [me, ana.id]))
        let drawn = await faces(of: view) { !$0.isEmpty }
        #expect(drawn.initials == ["A"], "named Ana Ruiz from the conversation that lists her, not \"user_ana\"")
        #expect(drawn.label == HomeStrings.alsoHere("Ana Ruiz"))
    }

    /// The faces once the store's change reached the view (its observation re-arms on the main
    /// actor); a bounded number of turns, no sleeping.
    private func faces(of view: HomeNativeTranscriptView, until done: ([String]) -> Bool) async -> (initials: [String], shown: Bool, label: String) {
        for _ in 0..<50 where !done(view.debugHeaderFaces.initials) {
            await Task.yield()
        }
        view.transcript.controller.host.layoutSubtreeIfNeeded()
        return view.debugHeaderFaces
    }
}
