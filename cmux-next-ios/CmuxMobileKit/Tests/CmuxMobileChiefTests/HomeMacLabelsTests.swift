#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileChief

/// Home with two Macs (user report 2026-10-21): each Chief and each row says
/// which Mac it belongs to, and the Mac filter scopes them.
@MainActor @Suite struct HomeMacLabelsTests {
    let laptop = MacDevice(id: "m1", name: "Aziz's MacBook Pro", isOnline: true)
    let other = MacDevice(id: "m2", name: "Abdulaziz's MacBook Pro (2)", isOnline: true)

    /// Two rows named "workspace-1" read apart: their agent and their Mac.
    @Test func rowsNameTheirAgentAndMac() {
        let home = HomeMacLabels(macs: [laptop, other], scope: .all)
        #expect(home.subtitle(harness: "codex", macID: "m1") == "Codex · Aziz's MacBook Pro")
        #expect(home.subtitle(harness: "claude", macID: "m2") == "Claude Code · Abdulaziz's MacBook Pro (2)")
    }

    /// One Mac: the Mac says nothing new; the agent still shows.
    @Test func oneMacShowsOnlyTheAgent() {
        let home = HomeMacLabels(macs: [laptop], scope: .all)
        #expect(home.subtitle(harness: "codex", macID: "m1") == "Codex")
    }

    /// Same-name Macs carry their tag, as on Workspaces.
    @Test func sameNameMacsAreTagged() {
        let twin = MacDevice(id: "zz99", name: "Aziz's MacBook Pro", isOnline: true)
        let home = HomeMacLabels(macs: [laptop, twin], scope: .all)
        #expect(home.subtitle(harness: "codex", macID: "zz99") != home.subtitle(harness: "codex", macID: "m1"))
    }

    /// The Cloud Chief is on no Mac; the Mac Chief names the Mac it runs on.
    @Test func chiefsSayWhereTheyRun() {
        let home = HomeMacLabels(macs: [laptop, other], scope: .all)
        #expect(home.chiefDetail(place: .cloud, macID: nil, macName: nil) == "Cloud")
        #expect(home.chiefDetail(place: .mac, macID: "m2", macName: "Abdulaziz's MacBook Pro (2)") == "Abdulaziz's MacBook Pro (2)")
        // A Mac Chief that never linked has no Mac to name.
        #expect(home.chiefDetail(place: .mac, macID: nil, macName: nil) == nil)
    }

    /// The filter scopes rows and the Mac Chief to one Mac; the Cloud Chief
    /// belongs to no Mac and stays.
    @Test func theMacFilterScopesRowsAndTheMacChief() {
        let home = HomeMacLabels(macs: [laptop, other], scope: .mac("m2"))
        #expect(home.includes(macID: "m2"))
        #expect(!home.includes(macID: "m1"))
        #expect(home.showsMacChief(macID: "m2"))
        #expect(!home.showsMacChief(macID: "m1"))
        let all = HomeMacLabels(macs: [laptop, other], scope: .all)
        #expect(all.includes(macID: "m1") && all.includes(macID: "m2"))
        #expect(all.showsMacChief(macID: "m1"))
    }

    /// A chosen Mac that left the team reads as All Macs.
    @Test func aGoneMacReadsAsAll() {
        let home = HomeMacLabels(macs: [laptop], scope: .mac("m2"))
        #expect(home.scope == .all)
        #expect(home.includes(macID: "m1"))
    }
}
#endif
