import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-06: "cloud workspaces are treated normally right? no weird grouping? if there's weird grouping i prob
/// wont like it". A new Cloud machine's first workspace (New Cloud Workspace, Move to Cloud) marked the machine's
/// section a remote group, so with one workspace per machine every Cloud workspace sat in a group of its own. It now
/// goes where any new workspace goes (`workspaces.newPlacement`) and names its machine on its second line; only New
/// Remote Group, which a person asks for, makes a remote group.
@MainActor @Suite(.serialized, .closesItsWindows)
struct CloudWorkspaceNoGroupTests {
    /// A sidebar document listing the two Cloud machines' sections, recording every op sent to it.
    private final class Remote: SidebarDocRemote {
        var applied: [String] = []
        var isAvailable: Bool { true }
        func get() async throws -> Data {
            Data(#"{"revision":"1","sections":[{"id":"sec_m_s-vm-a","kind":{"type":"machine","session_id":"s-vm-a"},"scroll":"flow"},{"id":"sec_m_s-vm-b","kind":{"type":"machine","session_id":"s-vm-b"},"scroll":"flow"}],"items":[]}"#.utf8)
        }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { reply }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { reply }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            applied.append(String(decoding: ops, as: UTF8.self))
            return reply
        }
        private var reply: SidebarDocReply { SidebarDocReply(revision: 2, inverse: Data("[]".utf8)) }
    }

    @MainActor private final class Refusals {
        var messages: [String] = []
    }

    @Test func aCloudMachinesFirstWorkspaceMakesNoGroupForItsMachine() async throws {
        let services = UnopenedCloudMachinesTests.services()
        defer { UnopenedCloudMachinesTests.closeWindows(services) }
        let remote = Remote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive && store.records.sections["sec_m_s-vm-b"] != nil }
        try #require(store.isActive)
        store.show(live: [])
        services.sidebarDoc.store = store
        // The marks go only to a shown document (`SidebarDocument.activeStore`).
        try #require(services.sidebarDoc.activeStore === store)
        // A mark the document's reducer refuses still counts: it was an attempt to make a group.
        let refusals = Refusals()
        store.onRefused = { refusals.messages.append($0) }
        let context = AppActionContext(services: services)
        // Two new machines, one workspace each: neither machine's section becomes a group. Their daemons are not
        // connected, so the open fails after the point where it marked the section.
        for id in ["vm-a", "vm-b"] {
            let session = UnopenedCloudMachinesTests.machine(services, id: id, workspaces: [])
            try #require(session.daemon.store.registryID == "s-\(id)", "the mark names the machine's section by this id")
            _ = try? await CloudHandlers.creationFlow(context).open(session)
        }
        // A mark is one op sent from the store's own task: give it the time it took on the base.
        await RapidWorkspaceCreateTests.wait(within: .seconds(2)) { remote.applied.contains { $0.contains("host_group") } || !refusals.messages.isEmpty }
        #expect(!remote.applied.contains { $0.contains("host_group") }, "a Cloud create made a remote group: \(remote.applied)")
        #expect(refusals.messages.isEmpty, "a Cloud create tried to make a remote group: \(refusals.messages)")
        #expect(store.records.sections.values.allSatisfy { !$0.hostGroup })
    }
}
