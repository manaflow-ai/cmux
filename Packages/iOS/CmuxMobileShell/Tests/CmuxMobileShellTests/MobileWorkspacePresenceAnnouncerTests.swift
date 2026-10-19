import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite(.timeLimit(.minutes(1))) @MainActor
struct MobileWorkspacePresenceAnnouncerTests {
    @Test("clearing selection fences an identity request that finishes after sign-out")
    func pendingIdentityCannotRestoreClearedWorkspace() async throws {
        let gate = MobilePresenceIdentityGate()
        let announcer = MobileWorkspacePresenceAnnouncer(
            transport: MobilePresenceRecordingTransport(),
            tokenSource: PresenceTokenSource(accessToken: { "test" }, currentUserID: { await gate.identity() })
        )
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "a", teamID: "team"))
        let selection = Task { await announcer.setWorkspaceScope(scope) }
        await gate.waitForIdentityRequest()
        await announcer.setWorkspaceScope(nil)
        await gate.releaseIdentity()
        await selection.value
        #expect(announcer.scope == nil)
    }

    @Test("an account change within one workspace captures new credentials")
    func accountChangeRestartsSelection() async throws {
        let identity = MobilePresenceIdentityGate(blockFirst: false)
        let transport = MobilePresenceRecordingTransport()
        let announcer = MobileWorkspacePresenceAnnouncer(
            transport: transport,
            tokenSource: PresenceTokenSource(accessToken: { await identity.current() }, currentUserID: { await identity.current() })
        )
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "a", teamID: "team"))
        await announcer.setWorkspaceScope(scope)
        #expect(await transport.nextToken() == "first")
        await identity.changeAccount()
        await announcer.setWorkspaceScope(scope)
        #expect(await transport.nextToken() == "second")
        await announcer.setWorkspaceScope(nil)
    }
}
