#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileChief

/// Home with two Macs (user report 2026-10-21): each Chief says where it runs.
@MainActor @Suite struct HomeMacLabelsTests {
    let laptop = MacDevice(id: "m1", name: "Aziz's MacBook Pro", isOnline: true)
    let other = MacDevice(id: "m2", name: "Abdulaziz's MacBook Pro (2)", isOnline: true)

    /// Same-name Macs carry their tag, as on Workspaces.
    @Test func sameNameMacsAreTagged() {
        let twin = MacDevice(id: "zz99", name: "Aziz's MacBook Pro", isOnline: true)
        let home = HomeMacLabels(macs: [laptop, twin], scope: .all)
        #expect(home.macName("zz99") != home.macName("m1"))
    }

    /// The Cloud Chief is on no Mac; the Mac Chief names the Mac it runs on.
    @Test func chiefsSayWhereTheyRun() {
        let home = HomeMacLabels(macs: [laptop, other], scope: .all)
        #expect(home.chiefDetail(place: .cloud, macID: nil, macName: nil) == "Cloud")
        #expect(home.chiefDetail(place: .mac, macID: "m2", macName: "Abdulaziz's MacBook Pro (2)") == "Abdulaziz's MacBook Pro (2)")
        // A Mac Chief that never linked has no Mac to name.
        #expect(home.chiefDetail(place: .mac, macID: nil, macName: nil) == nil)
    }

    /// Same-name tags use every listed Mac of the account, as Workspaces does.
    @Test func tagsFollowTheAccountsMacs() {
        let twin = MacDevice(id: "zz99", name: "Aziz's MacBook Pro", isOnline: true)
        let home = HomeMacLabels(macs: [laptop, other], scope: .all, accountMacs: [laptop, other, twin])
        #expect(home.macName("m1") != "Aziz's MacBook Pro")
    }

    /// A chosen Mac that left the team reads as All Macs.
    @Test func aGoneMacReadsAsAll() {
        let home = HomeMacLabels(macs: [laptop], scope: .mac("m2"))
        #expect(home.scope == .all)
    }
}
#endif
