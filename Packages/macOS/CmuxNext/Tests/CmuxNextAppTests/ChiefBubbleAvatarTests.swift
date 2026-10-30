import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// A group transcript's bubbles draw each Chief with the avatar its Home row
/// draws (`HomeSidebarModel`: its own avatar, else the default), and nobody
/// else: people keep their monogram.
@Suite struct ChiefBubbleAvatarTests {
    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    static let alice = Participant(id: ParticipantID("user_alice"), kind: .human, displayName: "Alice")
    static let mux = Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Chief", agentClass: .chief)
    static let scout = Participant(id: ParticipantID("agent_scout01"), kind: .agent, displayName: "Scout", agentClass: .chief)
    static let worker = Participant(id: ParticipantID("agent_worker"), kind: .agent, displayName: "Worker")

    @Test func eachChiefWearsItsOwnAvatarElseTheDefault() {
        let own = URL(fileURLWithPath: "/tmp/mux.png")
        let fallback = HomeChiefAvatar.picture(URL(fileURLWithPath: "/tmp/cat.png"))
        let avatars = HomeChiefAvatar.bubbleAvatars(for: [Self.me, Self.alice, Self.mux, Self.scout, Self.worker],
                                                    own: ["agent_mux": .picture(own), "user_alice": .text("A")],
                                                    fallback: fallback)
        #expect(avatars == ["agent_mux": .picture(own), "agent_scout01": fallback])
    }
}
