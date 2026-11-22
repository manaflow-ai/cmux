import Foundation
import Testing
@testable import CmuxNextDaemon

/// closed-history-v2 (plans/cmux-next/reopen-closed.md): one close gesture
/// is one item with a member per closed tab. The top-level fields mirror the
/// first member for v1 clients; the item's tabs are every member's tabs, so
/// the undo toast of "Close Others" (3 -> 1) counts both closed tabs.
@Suite struct ClosedGroupItemTests {
    static func member(_ name: String, index: Int) -> String {
        #"{"kind":"tab","name":"\#(name)","workspace_id":"ws_w","pane_id":"pane_p","index":\#(index),"screens":[{"name":null,"tabs":[{"kind":"terminal","name":"\#(name)","cwd":"/tmp","url":null,"browser_profile_id":null,"pinned":false}]}]}"#
    }

    /// The JSON `public_item` (closed_history_query.rs) sends for a two-tab gesture.
    static let group = #"{"id":"closed_g","kind":"tab","name":"a","workspace_id":"ws_w","pane_id":"pane_p","index":1,"closed_at_ms":"5","screens":[{"name":null,"tabs":[{"kind":"terminal","name":"a","cwd":"/tmp","url":null,"browser_profile_id":null,"pinned":false}]}],"window":null,"member_count":2,"members":[\#(member("a", index: 1)),\#(member("b", index: 2))]}"#

    @Test func aGroupItemListsTheTabsOfEveryMember() throws {
        let item = try JSONDecoder().decode(ClosedItem.self, from: Data(Self.group.utf8))
        #expect(item.tabs.map(\.name) == ["a", "b"])
        #expect(item.paneID?.rawValue == "pane_p")
    }

    /// A deleted personal workspace group: no member, and `group` names it.
    @Test func aDeletedGroupItemNamesTheGroup() throws {
        let json = ##"{"id":"closed_w","kind":"workspace","name":null,"workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":"7","screens":[],"window":null,"member_count":0,"members":[],"group":{"id":"grp_work","name":"Work","color":"#225588"}}"##
        let item = try JSONDecoder().decode(ClosedItem.self, from: Data(json.utf8))
        #expect(item.group == ClosedItem.Group(id: "grp_work", name: "Work", color: "#225588"))
        #expect(item.tabs.isEmpty)
        let plain = try JSONDecoder().decode(ClosedItem.self, from: Data(Self.group.utf8))
        #expect(plain.group == nil)
    }

    /// workspace-group-icon-v1: the record carries the deleted group's icon.
    @Test func aDeletedGroupItemCarriesTheGroupIcon() throws {
        let json = ##"{"id":"closed_w","kind":"workspace","name":null,"workspace_id":null,"pane_id":null,"index":0,"closed_at_ms":"7","screens":[],"window":null,"member_count":0,"members":[],"group":{"id":"grp_work","name":"Work","color":null,"icon":"star.fill"}}"##
        let item = try JSONDecoder().decode(ClosedItem.self, from: Data(json.utf8))
        #expect(item.group?.icon == "star.fill")
    }

    /// A v1 item (no members) keeps its own screens.
    @Test func aV1ItemKeepsItsScreens() throws {
        let item = try JSONDecoder().decode(ClosedItem.self, from: Data(Self.member("solo", index: 0).replacingOccurrences(
            of: #"{"kind":"tab","#, with: #"{"id":"closed_1","kind":"tab","closed_at_ms":"1","#).utf8))
        #expect(item.tabs.map(\.name) == ["solo"])
    }
}
