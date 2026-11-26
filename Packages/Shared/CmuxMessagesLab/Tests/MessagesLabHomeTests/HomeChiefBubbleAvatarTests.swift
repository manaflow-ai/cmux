import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A group's Chief wears its chosen avatar beside its bubbles, as Home's
/// header and row do, and a new avatar redraws those bubbles while the
/// conversation is open. Someone with no avatar of their own keeps their
/// monogram. Each case maps HomeStore items through `ProjectionCore` and
/// derives the rows with `RowBuilder`, as `HomeGroupSenderTests` does.
@MainActor @Suite struct HomeChiefBubbleAvatarTests {
    typealias G = HomeGroupSenderTests
    static let picture = "file:///Users/me/.cmux/chiefs/agent_chief/3f2a.png"

    /// The avatar beside the last bubble of each incoming run, by its text.
    static func avatars(_ state: AppState) -> [String: SenderAvatar] {
        var out: [String: SenderAvatar] = [:]
        for row in RowBuilder.rows(state, messages: state.conversation.messages, now: G.date(60)) {
            guard case let .part(p) = row.kind, case let .text(t, _) = p.part, !p.outgoing, let avatar = p.cmuxAvatar else { continue }
            out[t] = avatar
        }
        return out
    }

    @Test func aGroupsChiefWearsItsChosenAvatarAndOthersTheirMonogram() {
        var core = ProjectionCore(me: G.me)
        let early = core.setAvatars([G.chief.rawValue: .image(Self.picture)])
        #expect(early == nil, "nothing is shown before the install")
        let (conv, _) = core.install(G.id, items: G.items([G.chief, G.me, G.alice]), summary: G.summary([G.me, G.alice, G.chief]))
        #expect(Self.avatars(AppState(conversation: conv)) == ["m1": .image(Self.picture), "m3": .monogram("AS")])
    }

    @Test func aNewAvatarRedrawsTheChiefsBubblesInTheOpenConversation() throws {
        var core = ProjectionCore(me: G.me)
        let (conv, _) = core.install(G.id, items: G.items([G.chief, G.me, G.alice]), summary: G.summary([G.me, G.alice, G.chief]))
        var state = AppState(conversation: conv)
        #expect(Self.avatars(state)["m1"] == .monogram("C"), "no chosen avatar: the Chief's monogram")

        let picked = core.setAvatars([G.chief.rawValue: .image(Self.picture)])
        let swap = try #require(picked)
        _ = Reducer.reduce(&state, swap, now: G.date(61), newID: { "new" })
        #expect(Self.avatars(state) == ["m1": .image(Self.picture), "m3": .monogram("AS")])
        let again = core.setAvatars([G.chief.rawValue: .image(Self.picture)])
        #expect(again == nil, "the same avatars change nothing")

        let saluted = core.setAvatars([G.chief.rawValue: .monogram("🫡")])
        let text = try #require(saluted)
        _ = Reducer.reduce(&state, text, now: G.date(62), newID: { "new" })
        #expect(Self.avatars(state)["m1"] == .monogram("🫡"))
        #expect(state.conversation.messages.map(\.id) == conv.messages.map(\.id), "the messages stay")
    }
}
