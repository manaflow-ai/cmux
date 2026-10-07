import Foundation
import Testing
@testable import CmuxNextApp

/// Home's Chief tab shows the chief placed on a paired server (G6), else the
/// local mux conversation.
@MainActor
@Suite struct HomeChiefSourceTests {
    private static func chief(_ id: String, isDefault: Bool, main: String?, placed: Bool) -> [String: Any] {
        var value: [String: Any] = ["id": id, "display_name": "Chief", "is_default": isDefault, "rev": 2,
                                    "main_conversation": main ?? NSNull()]
        value["brain_place"] = placed ? ["host": "host_aaaaaaaaaaaaaaaaaaaa", "install": "inst_aaaaaaaaaaaaaaaaaaaa"] : NSNull()
        return value
    }

    @Test func aPlacedChiefWinsOverALocalChiefWithoutHistory() {
        let placed = CloudChief.parse(Self.chief("agent_A", isDefault: true, main: "conv_A", placed: true))
        #expect(HomeChiefSource.choose(local: "local-1", localHasHistory: false, placed: placed) == "conv_A")
        #expect(HomeChiefSource.choose(local: "local-1", localHasHistory: true, placed: nil) == "local-1")
        #expect(HomeChiefSource.choose(local: nil, localHasHistory: false, placed: placed) == "conv_A")
        #expect(HomeChiefSource.choose(local: nil, localHasHistory: false, placed: nil) == nil)
    }

    /// One history (home-state-ownership.md): a placed chief whose cloud
    /// conversation does not hold the local Chief's history never hides it.
    /// On nxchief1 (cmux-lawrence-2, 2026-10-06) a relaunch signed in to an
    /// account with a placed chief moved the Chief tab to that chief's empty
    /// cloud conversation: the two messages the local Chief held vanished
    /// from Home and a send went nowhere. Until the brain move imports the
    /// conversation (DESIGN-cmux-lawrence.md section 5 step 3), the local
    /// Chief with history stays the Chief tab.
    @Test func aPlacedChiefNeverHidesTheLocalChiefsHistory() {
        let placed = CloudChief.parse(Self.chief("agent_A", isDefault: true, main: "conv_A", placed: true))
        #expect(HomeChiefSource.choose(local: "local-1", localHasHistory: true, placed: placed) == "local-1")
        #expect(HomeChiefSource.choose(local: "local-1", localHasHistory: false, placed: placed) == "conv_A")
    }

    @Test func readPlacedListsChiefsAndPicksThePlacedOne() async throws {
        var calls: [(String, [String: Any])] = []
        let chiefs = [Self.chief("agent_U", isDefault: true, main: "conv_U", placed: false),
                      Self.chief("agent_P", isDefault: false, main: "conv_P", placed: true)]
        let placed = try await HomeChiefSource.readPlaced { path, body in
            calls.append((path, body))
            return ["value": ["chiefs": chiefs, "tombstones": [Any]()]]
        }
        #expect(placed?.id == "agent_P")
        #expect(placed?.mainConversation == "conv_P")
        #expect(calls.first?.0 == "v1/read")
        #expect(calls.first?.1["op"] as? String == "chief.list")
    }

    /// No placed chief (or an older backend without brain_place) keeps the local chief.
    @Test func noPlacedChiefReadsNil() async throws {
        let unplaced = try await HomeChiefSource.readPlaced { _, _ in
            ["value": ["chiefs": [Self.chief("agent_U", isDefault: true, main: "conv_U", placed: false)]]]
        }
        #expect(unplaced == nil)
        let noMain = try await HomeChiefSource.readPlaced { _, _ in
            ["value": ["chiefs": [Self.chief("agent_P", isDefault: true, main: nil, placed: true)]]]
        }
        #expect(noMain == nil)
    }
}
