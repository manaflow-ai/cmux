import CmuxNextIcons
import CmuxNextResources
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-08 dogfood, Codex parity): the workspace hover card is a
/// title row (name, a kind or host icon, relative age) and one row per
/// meaningful fact with an icon; resources show only when notable.
@MainActor @Suite struct WorkspaceHoverCardContentTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theCardShowsWithoutAHoverDelay() {
        #expect(WorkspaceHoverCardController().delay == .zero)
    }

    @Test func titleRowAndFactsReadLikeCodex() {
        let workspace = SidebarWorkspace(
            id: WorkspaceID("w"), title: "Play Starsector campaign", directory: "~/Projects/projects folder",
            branch: "main", lastActivity: now.addingTimeInterval(-28 * 86_400))
        let content = WorkspaceHoverCardContent.make(workspace, machine: nil, now: now)
        #expect(content.title == "Play Starsector campaign")
        #expect(content.icon == workspace.kind.iconName)
        // "4w" in English; the units follow the person's locale.
        #expect(content.age?.contains("4") == true)
        #expect(content.facts == [
            .init(icon: .folder, text: "projects folder"),
            .init(icon: .gitBranch, text: "main"),
        ])
    }

    @Test func aRemoteWorkspaceShowsItsHost() {
        let workspace = SidebarWorkspace(id: WorkspaceID("w"), machineID: MachineID("box"), title: "w", directory: "~")
        let machine = SidebarMachine(id: MachineID("box"), name: "build box", kind: .ssh)
        let content = WorkspaceHoverCardContent.make(workspace, machine: machine, now: now)
        #expect(content.icon == .machineRemote)
        #expect(content.facts.contains(.init(icon: .machineRemote, text: "build box")))
        // The home folder reads as a name, never "~".
        #expect(!content.facts.contains { $0.text == "~" })
        #expect(content.age == nil, "no activity, no age")
    }

    @Test func anEmptyFolderIsNoRow() {
        let workspace = SidebarWorkspace(id: WorkspaceID("w"), title: "w", directory: "")
        #expect(WorkspaceHoverCardContent.make(workspace, machine: nil, now: now).facts.isEmpty)
    }

    @Test func resourcesShowOnlyWhenNotable() {
        let quiet = ResourceReport(total: ResourceUsage(cpu: 0.02, memoryBytes: 70 << 20))
        let busy = ResourceReport(total: ResourceUsage(cpu: 1.4, memoryBytes: 70 << 20))
        let large = ResourceReport(total: ResourceUsage(cpu: 0.01, memoryBytes: 3 << 30))
        #expect(WorkspaceHoverCardContent.resourceLine(quiet) == nil)
        #expect(WorkspaceHoverCardContent.resourceLine(nil) == nil)
        #expect(WorkspaceHoverCardContent.resourceLine(busy) == ResourceFormat.line(busy.total))
        #expect(WorkspaceHoverCardContent.resourceLine(large) == ResourceFormat.line(large.total))
    }
}
