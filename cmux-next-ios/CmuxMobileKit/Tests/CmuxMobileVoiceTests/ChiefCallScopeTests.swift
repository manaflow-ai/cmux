import CmuxConversationCore
import CmuxMobileChief
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileVoice

/// A call is to the Chief the user called, and only it (Aziz 2026-11-05: "the chief I
/// called was only able to see the cloud chief"). Before the fix every call read, briefed
/// and sent to ``ChiefSources/primary``, the Cloud Chief once it answers.
@MainActor
@Suite struct ChiefCallScopeTests {
    static func chief(_ id: String, _ title: String) -> ChiefSession {
        ChiefSession(backend: ChiefOfflineBackend(), identity: ChiefIdentity(chiefID: id, title: title))
    }

    static func toolbox(_ chief: ChiefSession) -> ChiefCallToolbox {
        ChiefCallToolbox(chief: chief, store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []), userName: nil)
    }

    #if DEBUG
    /// Resumes once `chief`'s store has a sender (the mock Chief connected).
    static func connected(_ chief: ChiefSession) async {
        if chief.store.meID != nil { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var token: Int?
            token = chief.store.addObserver { _ in
                guard let mine = token, chief.store.meID != nil else { return }
                token = nil
                chief.store.removeObserver(mine)
                done.resume()
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func aCallSendsOnlyToTheChiefCalled() async {
        let mac = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), identity: ChiefIdentity(chiefID: "agent_mux", title: "Chief"))
        let cloud = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), identity: ChiefIdentity(chiefID: "agent_atlas", title: "Atlas"))
        defer { mac.store.stop(); cloud.store.stop() }
        await Self.connected(mac)
        await Self.connected(cloud)
        let toolbox = Self.toolbox(mac)
        #expect(toolbox.chiefName == "Chief")
        _ = await toolbox.sendToChief("Run the tests again.")
        #expect(mac.store.messages.contains { $0.text == "Run the tests again." })
        #expect(!cloud.store.messages.contains { $0.text == "Run the tests again." }, "the other Chief got the call's message")
    }
    #endif

    @Test func theBriefingIsTheCalledChiefs() {
        let text = Self.toolbox(Self.chief("agent_atlas", "Atlas")).briefing().instructions(now: Date())
        #expect(text.contains("You are Atlas"))
        #expect(text.contains("this call is with Atlas only"))
    }

    /// The Cloud session is shared by the account's Cloud Chiefs: opening another one on Home
    /// switches it. The call stays the called Chief's and reads and sends nothing after that.
    @Test func aCallReadsAndSendsNothingOnceItsSessionShowsAnotherChief() async {
        let cloud = Self.chief("agent_atlas", "Atlas")
        let toolbox = Self.toolbox(cloud)
        #expect(toolbox.isScoped)
        cloud.use(ChiefOfflineBackend(), identity: ChiefIdentity(chiefID: "agent_nova", title: "Nova"))
        #expect(!toolbox.isScoped)
        let sent = await toolbox.sendToChief("Push the branch.")
        #expect(sent.output.contains("chief_closed"))
        #expect(!cloud.store.messages.contains { $0.text == "Push the branch." }, "a call to Atlas sent to Nova")
        #expect(cloud.store.draft.isEmpty)
        #expect(toolbox.readChiefMessages(count: 5).output.contains("chief_closed"))
        #expect(toolbox.chiefName == "Atlas")
    }

    /// Every Mac's Chief has the same id and the Mac Chief's session follows the Mac shown:
    /// a call to one Mac's Chief never reaches another Mac's.
    @Test func aCallToOneMacsChiefNeverReachesAnotherMacs() async {
        let mac = Self.chief("agent_mux", "Chief")
        mac.macID = "mac-studio"
        let toolbox = Self.toolbox(mac)
        #expect(toolbox.isScoped)
        mac.macID = "mac-air"
        #expect(!toolbox.isScoped)
        let sent = await toolbox.sendToChief("Run the tests again.")
        #expect(sent.output.contains("chief_closed"))
        #expect(mac.store.messages.isEmpty)
        #expect(mac.store.draft.isEmpty)
    }

    /// No outbox: a call to a Chief that is offline says nothing was sent, never "queued".
    @Test func aCallToAnOfflineChiefSaysNotSent() async {
        let mac = Self.chief("agent_mux", "Chief")
        let sent = await Self.toolbox(mac).sendToChief("Run the tests again.")
        #expect(sent.output.contains("not_sent"))
        #expect(mac.store.messages.isEmpty)
    }
}
