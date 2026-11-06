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
        ChiefSession(backend: ChiefOfflineBackend(), identity: ChiefIdentity(chiefID: id, title: title),
                     outbox: ChiefOutbox(file: nil))
    }

    static func toolbox(_ chief: ChiefSession) -> ChiefCallToolbox {
        ChiefCallToolbox(chief: chief, store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []), userName: nil)
    }

    @Test func aCallSendsOnlyToTheChiefCalled() async {
        let mac = Self.chief("agent_mux", "Chief")
        let cloud = Self.chief("agent_atlas", "Atlas")
        let toolbox = Self.toolbox(mac)
        #expect(toolbox.chiefName == "Chief")
        _ = await toolbox.sendToChief("Run the tests again.")
        #expect(mac.outbox.map(\.text) == ["Run the tests again."])
        #expect(cloud.outbox.isEmpty, "the other Chief got the call's message")
    }

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
        #expect(cloud.outbox.isEmpty, "a call to Atlas sent to Nova")
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
        #expect(mac.outbox.isEmpty)
    }
}
