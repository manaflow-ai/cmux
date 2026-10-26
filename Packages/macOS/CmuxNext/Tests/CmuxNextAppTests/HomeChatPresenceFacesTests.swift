import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// Leo 2026-10-26: "also chief chats we need multiplayer". Who else has the Chief chat open shows
/// as faces beside the header's name pill, from the owner's presence, never with this user's own.
@MainActor @Suite(.serialized) struct HomeChatPresenceFacesTests {
    let conv = ConversationID("conv_faces")
    let me = ParticipantID("user_me")

    @Test func othersAreNamedFromTheConversationInNameOrderWithoutMe() {
        let people = [
            Participant(id: me, kind: .human, displayName: "Me"),
            Participant(id: ParticipantID("user_sam"), kind: .human, displayName: "Sam Okafor"),
            Participant(id: ParticipantID("user_ana"), kind: .human, displayName: " Ana Ruiz "),
            Participant(id: ParticipantID("user_blank"), kind: .human, displayName: "  "),
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
