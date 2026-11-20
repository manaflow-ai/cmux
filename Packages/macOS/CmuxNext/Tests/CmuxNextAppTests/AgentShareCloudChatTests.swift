import CmuxNextActions
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// Share a Cloud chat (cloud multiplayer lane C): a chat on the person's own Cloud machine is
/// shared through that machine's daemon like this Mac's; one on a teammate's machine is refused
/// before any token is minted, and a machine whose daemon names no share room is refused before
/// a token goes to it. Before, every chat off this Mac was refused "Only a chat on this Mac can be
/// shared."
@MainActor @Suite struct AgentShareCloudChatTests {
    /// Counts the owner tokens minted: a refused share mints none.
    @MainActor final class Host: AgentShareHost {
        var minted = 0
        func shareTab(surface: SurfaceID) -> TabModel? { nil }
        func shareTab(id: String) -> TabModel? { nil }
        func shareTabID(showing session: String) -> String? { nil }
        var shareFocusedTabID: String? { nil }
        func shareConnection(holding tab: TabModel) -> DaemonConnection? { nil }
        func shareIsOnThisMac(_ tab: TabModel) -> Bool { false }
        var shareLocalConnection: DaemonConnection? { nil }
        func shareOwnerToken(api: URL?) async -> String? { minted += 1; return "token" }
        func shareCopy(_ text: String) {}
        func shareNotice(_ message: String) {}
    }

    static func cloudChat(owner: Bool?) -> AgentShareChat {
        AgentShareChat(surface: 3, session: "acp_1", connection: nil, isLocal: false, title: "Cloud chat",
                       cloudOwner: owner.map { owned -> @MainActor @Sendable () async -> Bool in { owned } })
    }

    @Test func aChatOnAnotherMachineThatIsNoCloudMachineIsNotShareable() {
        #expect(!Self.cloudChat(owner: nil).shareable)
        #expect(Self.cloudChat(owner: false).shareable, "the owner check runs on the link, before any token")
        #expect(AgentShareChat(surface: 1, connection: nil).shareable)
    }

    @Test func aTeammatesCloudChatIsRefusedBeforeATokenIsMinted() async {
        let host = Host()
        await #expect(throws: AgentShareNotCloudOwner.self) {
            _ = try await AgentShareActions.create(Self.cloudChat(owner: false), ttl: nil, uses: nil, host: host)
        }
        #expect(host.minted == 0)
        let failure = AgentShareStrings.failure(AgentShareNotCloudOwner())
        #expect(failure.code == "share.not_owner")
    }

    @Test func anOwnedCloudChatWithNoRoomIsRefusedBeforeATokenGoesToTheMachine() async {
        let host = Host()
        await #expect(throws: AgentShareCloudRoomMissing.self) {
            _ = try await AgentShareActions.create(Self.cloudChat(owner: true), ttl: nil, uses: nil, host: host)
        }
        #expect(host.minted == 0)
        #expect(AgentShareStrings.failure(AgentShareCloudRoomMissing()).code == "share.room_unconfigured")
    }
}
