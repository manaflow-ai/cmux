@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Lawrence 2026-10-09: subagent tabs made before chief:<home id> existed record this Mac's
/// install host, so they kept attaching to the app's acpmux ("This chat isn't available").
/// Their sessions run in the Chief home's acpmux, tagged `mux.parent=optchat-chief:<home id>`:
/// the router asks that one daemon (never a search) and attaches the tab there.
struct AcpmuxChiefSessionRouterTests {
    actor Recorder: AgentPaneHostProviding {
        private(set) var asked: [String?] = []
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            asked.append(sessionId)
            return .mock
        }
    }

    @Test func aChiefSubagentSessionIsAttachedToTheChiefHomesAcpmux() async throws {
        let local = Recorder(), chief = Recorder()
        let router = AcpmuxChiefSessionRouter(local: local, chief: chief) { $0 == "s-sub" }
        _ = try await router.handshake(sessionId: "s-sub")
        _ = try await router.handshake(sessionId: "s-mine")
        _ = try await router.handshake(sessionId: nil)
        #expect(await chief.asked == ["s-sub"])
        #expect(await local.asked == ["s-mine", nil])
    }

    @Test func ownershipIsTheParentTagInTheChiefHomesListing() {
        let listing: [String: Any] = ["sessions": [
            ["sessionId": "s-sub", "tags": ["mux.parent": "optchat-chief:0a1b2c3d"]],
            ["sessionId": "s-other", "tags": ["mux.parent": "optchat-chief:ffffffff"]],
            ["sessionId": "s-plain"],
        ]]
        let tag = "optchat-chief:0a1b2c3d"
        #expect(AcpmuxChiefSessionRouter.owns(listing, session: "s-sub", parentTag: tag))
        #expect(!AcpmuxChiefSessionRouter.owns(listing, session: "s-other", parentTag: tag))
        #expect(!AcpmuxChiefSessionRouter.owns(listing, session: "s-plain", parentTag: tag))
        #expect(!AcpmuxChiefSessionRouter.owns(listing, session: "s-missing", parentTag: tag))
    }
}
