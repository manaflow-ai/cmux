import CmuxChiefList
import Foundation
import Testing
@testable import CmuxMobileChief

/// The iPhone's Home lists the same Chiefs as the Mac's Home, by the same rule (``HomeChiefs`` calls
/// CmuxChiefList's `ChiefList`, which the Mac's `HomeChiefRoster` calls). Before, the phone listed
/// only the open Cloud Chief, always tagged it Main, and tagged no other Chief with its place.
@Suite struct HomeChiefsTests {
    static func row(_ id: String, kind: String = "chief") -> MacHomeRow {
        MacHomeRow(wire: ["id": id, "kind": kind, "name": id, "activity_at": "2026-11-17T10:00:00Z"])! // crash-allow: test fixture
    }

    static func cloud(_ id: String, main: String?, isDefault: Bool = false, host: String? = nil) -> CloudChief {
        CloudChief(id: id, displayName: id, isDefault: isDefault, mainConversation: main, rev: 1,
                   brainPlace: host.map { CloudChief.BrainPlace(host: $0, install: "i") })
    }

    static let rows = [row("mac"), row("mac-named"), row("dm", kind: "direct")]
    static let cloud = [cloud("hosted", main: "c-hosted", isDefault: true), cloud("ops", main: "c-ops"), cloud("new", main: nil)]

    @Test func listsTheMacsChiefsAndEveryCloudChief() {
        let chiefs = HomeChiefs(macRows: Self.rows, macChief: "mac", cloud: Self.cloud, open: Self.cloud[0])
        #expect(chiefs.list.conversations == ["mac", "mac-named", "c-hosted", "c-ops"])
        #expect(chiefs.tag(for: "c-ops", macName: "Aziz's MacBook") == "Cloud")
        #expect(chiefs.tag(for: "mac-named", macName: "Aziz's MacBook") == "Aziz's MacBook")
    }

    @Test func mainIsTheMacsChiefWhileItIsListedAsOnTheMac() {
        // The Mac's Auto default: its own Chief while it answers, the cloud Chief otherwise.
        let chiefs = HomeChiefs(macRows: Self.rows, macChief: "mac", cloud: Self.cloud, open: Self.cloud[0])
        #expect(chiefs.list.main == "mac")
        #expect(chiefs.tag(for: "mac", macName: "Aziz's MacBook") == "Main \u{00B7} Aziz's MacBook")
        #expect(chiefs.tag(for: "c-hosted", macName: "Aziz's MacBook") == "Cloud")
        let noMac = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud, open: Self.cloud[0])
        #expect(noMac.list.main == "c-hosted")
        #expect(noMac.tag(for: "c-hosted", macName: nil) == "Main \u{00B7} Cloud")
    }

    @Test func beforeTheMacsListArrivesTheReadyCloudChiefIsMain() {
        let chiefs = HomeChiefs(macRows: nil, macChief: "mac", cloud: Self.cloud, open: Self.cloud[0])
        #expect(chiefs.list.conversations == ["c-hosted", "c-ops"])
        #expect(chiefs.list.main == "c-hosted")
        #expect(HomeChiefs(macRows: nil, macChief: "mac", cloud: [], open: nil).list.main == nil)
    }

    @Test func aCloudChiefTheMacAlsoListsIsListedOnceAsTheMacsRow() {
        let chiefs = HomeChiefs(macRows: Self.rows + [Self.row("c-ops")], macChief: "mac", cloud: Self.cloud, open: Self.cloud[0])
        #expect(chiefs.list.conversations == ["mac", "mac-named", "c-ops", "c-hosted"])
        // Tagged where it runs, as the Mac tags its cloud owner's rows: "Cloud", not the Mac's name.
        #expect(chiefs.tag(for: "c-ops", macName: "Aziz's MacBook") == "Cloud")
        let mac = ChiefListMacInputs.list(rows: ["mac", "mac-named", "c-ops", "c-hosted"], cloud: ["c-hosted", "c-ops"],
                                          local: "mac", hosted: "c-hosted", prefersLocal: true)
        #expect(chiefs.list == mac)
    }

    @Test func aPlacedChiefTheUserOpenedIsMainAndNamesItsServer() {
        let placed = Self.cloud("mini", main: "c-mini", host: "cmux20")
        let chiefs = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud + [placed], open: placed)
        #expect(chiefs.list.main == "c-mini")
        #expect(chiefs.tag(for: "c-mini", macName: nil) == "Main \u{00B7} cmux20")
    }

    @Test func aPlacedChiefIsTaggedWithItsServersNameElseItsHostID() {
        // The Mac's rule (`serverName(of:)`): the paired server's name, its host id while unknown.
        let placed = Self.cloud("mini", main: "c-mini", host: "host-7f3a")
        let named = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud + [placed], open: placed,
                               serverName: { $0 == "host-7f3a" ? "Studio mini" : nil })
        #expect(named.tag(for: "c-mini", macName: nil) == "Main \u{00B7} Studio mini")
        let unknown = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud + [placed], open: placed)
        #expect(unknown.tag(for: "c-mini", macName: nil) == "Main \u{00B7} host-7f3a")
    }

    @Test func serverNamesComeFromTheTeamsHostList() {
        // `team.hosts.list`: the ids `brain_place.host` names, with each host's name.
        let names = ChiefSources.hostNames(["hosts": [["id": "host_7f3a", "name": "Studio mini", "platform": "macos"],
                                                      ["id": "host_unnamed", "name": ""], ["name": "no id"]]])
        #expect(names == ["host_7f3a": "Studio mini"])
        let placed = Self.cloud("mini", main: "c-mini", host: "host_7f3a")
        let chiefs = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud + [placed], open: placed, serverName: { names[$0] })
        #expect(chiefs.tag(for: "c-mini", macName: nil) == "Main \u{00B7} Studio mini")
    }

    @Test func pickersLeadWithTheMainChief() {
        let chiefs = HomeChiefs(macRows: [], macChief: nil, cloud: Self.cloud, open: Self.cloud[0])
        #expect(chiefs.mainFirst(["c-ops", "c-hosted"]) { $0 } == ["c-hosted", "c-ops"])
    }

    /// The same inputs give the Mac's list and the phone's the same Chiefs, Main and places.
    @Test func thePhoneAndTheMacComputeTheSameList() {
        let phone = HomeChiefs(macRows: Self.rows, macChief: "mac", cloud: Self.cloud, open: Self.cloud[0]).list
        let mac = ChiefListMacInputs.list(rows: ["mac", "mac-named", "c-hosted", "c-ops"], cloud: ["c-hosted", "c-ops"],
                                          local: "mac", hosted: "c-hosted", prefersLocal: true)
        #expect(phone == mac)
    }
}

/// What the Mac's `HomeChiefRoster.make` passes the shared rule for the same Home (its Chief rows
/// with the cloud owner's marked, its local, hosted and placed Chiefs and its Engine row's answer).
struct ChiefListMacInputs {
    static func list(rows: [String], cloud: Set<String>, local: String?, hosted: String?, prefersLocal: Bool) -> ChiefList {
        ChiefList(chiefs: rows.map { ChiefList.Chief(conversation: $0, isCloud: cloud.contains($0)) }, local: local, hosted: hosted,
                  placed: nil, server: nil, showsPlaced: false, prefersLocal: prefersLocal)
    }
}
