import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The app and the mux host pick the same Chief conversation
/// (select_chief_conversation): the OLDEST local conversation with agent_mux,
/// by created_at then id, whatever the list order; and the host's create
/// request uses the app's user name (MUX_USER_NAME), so the owner never sees
/// two different "home-chief" creates.
@MainActor
@Suite struct HomeChiefSelectionTests {
    static let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
    static let other = ConversationParticipant(id: "user_other", kind: .human, displayName: "Other")

    static func summary(_ id: String, created: String, mux: Bool = true) -> CmuxNextDaemon.ConversationSummary {
        CmuxNextDaemon.ConversationSummary(id: id, title: id, participants: mux ? [me, HomeService.mux] : [me, other], lastSeq: 0, rev: 1,
                                           createdAt: created, updatedAt: "2026-10-03T12:00:00.000Z", lastMessage: nil, readCursors: [:])
    }

    @Test func theOldestMuxConversationIsTheChiefWhateverTheListOrder() {
        let list = [Self.summary("conv_new", created: "2026-10-03T09:00:00.000Z"),
                    Self.summary("conv_plain", created: "2026-09-01T00:00:00.000Z", mux: false),
                    Self.summary("conv_b", created: "2026-10-01T00:00:00.000Z"),
                    Self.summary("conv_a", created: "2026-10-01T00:00:00.000Z")]
        #expect(HomeChiefName.select(from: list)?.id == "conv_a")
        #expect(HomeChiefName.select(from: [Self.summary("conv_plain", created: "2026-09-01T00:00:00.000Z", mux: false)]) == nil)
    }

    @Test func theMuxHostGetsTheAppsUserName() throws {
        let host = HomeBrainHost(executable: URL(fileURLWithPath: "/bin/true"), muxHome: URL(fileURLWithPath: NSTemporaryDirectory()),
                                 daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock", acpmux: nil)
        #expect(host.childEnvironment["MUX_USER_NAME"] == HomeService.localUser.displayName)
        #expect(HomeService.localUser.displayName == HomeChiefName.localUserName)
    }
}
