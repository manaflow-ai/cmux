import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Home approval card answers a permission as the person only for a session the card's
/// Chief runs (review of PR 22639, finding 1): its turn (`cmux.chief` = the home id, role
/// `turn`) or a subagent it spawned (`mux.parent` = `optchat-chief:<id>`). Any other session,
/// another Chief's included, answers nothing.
struct ChiefApprovalSessionTests {
    static var listing: [String: Any] { ["sessions": [
        ["sessionId": "turn-1", "tags": ["cmux.chief": "b902d10e", "cmux.chief.role": "turn"]],
        ["sessionId": "compact-1", "tags": ["cmux.chief": "b902d10e", "cmux.chief.role": "compactor"]],
        ["sessionId": "sub-1", "tags": ["mux.parent": "optchat-chief:b902d10e", "optchat.subagent": "a1"]],
        ["sessionId": "other-chief", "tags": ["cmux.chief": "0badc0de", "cmux.chief.role": "turn"]],
        ["sessionId": "chat-1", "tags": [String: String]()],
        ["sessionId": "untagged"],
    ]] }

    @Test func theChiefsTurnAndSubagentsCount() {
        #expect(AcpmuxApprovalAnswerer.isChiefSession(Self.listing, session: "turn-1", chiefHomeID: "b902d10e"))
        #expect(AcpmuxApprovalAnswerer.isChiefSession(Self.listing, session: "sub-1", chiefHomeID: "b902d10e"))
    }

    @Test func anyOtherSessionDoesNot() {
        for session in ["compact-1", "other-chief", "chat-1", "untagged", "missing"] {
            #expect(!AcpmuxApprovalAnswerer.isChiefSession(Self.listing, session: session, chiefHomeID: "b902d10e"), "\(session)")
        }
        // Another Chief's turn is not this Chief's.
        #expect(!AcpmuxApprovalAnswerer.isChiefSession(Self.listing, session: "turn-1", chiefHomeID: "0badc0de"))
        #expect(!AcpmuxApprovalAnswerer.isChiefSession([:], session: "turn-1", chiefHomeID: "b902d10e"))
    }
}
