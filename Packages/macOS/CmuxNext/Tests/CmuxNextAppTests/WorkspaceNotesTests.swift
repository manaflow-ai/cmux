import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A workspace's description (`workspace-description-v1`) and its manual task status
/// (`workspace-status-v1`, classic cmux's lanes) are working actions, not greyed-out rows:
/// Edit / Clear Workspace Description, Mark Workspace as Done, Cycle Workspace Status and Set
/// Workspace Status run on a daemon that serves them. The daemon keeps both on the workspace
/// (`extra.description`, `extra.task_status`); the sidebar row leads its second line with the
/// description's first line, while the hover card shows the whole description and names the lane.
/// Status dots already carry the lane state at the row's trailing edge.
@MainActor @Suite(.serialized)
struct WorkspaceNotesTests {
    static let ids: [ActionID] = [
        "editWorkspaceDescription", "palette.clearWorkspaceDescription",
        "markWorkspaceDone", "cycleWorkspaceStatus", "palette.workspaceStatus",
    ]

    /// App services whose local daemon answered with `capabilities`, with every action bound.
    static func services(capabilities: [String]) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.noteHandshake(DaemonIdentity(capabilities: capabilities, generation: "notes-test"))
        AppActions.bind(services)
        return services
    }

    /// The sidebar row of one workspace (with the user icon `icon`) whose session snapshot carries `extra`.
    static func row(extra: String, icon: String? = nil) throws -> SidebarWorkspace {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: ResourceID(rawValue: "ws_notes"), name: "release", icon: icon),
        ]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":[{"id":"ws_notes","extra":\#(extra)}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        let sections = SidebarMapping.shared.sections(store.sidebarSections,
                                                      machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        return try #require(sections.flatMap(\.workspaces).first)
    }

    @Test func theActionsRunOnADaemonThatServesThem() {
        let services = Self.services(capabilities: ["workspace-description-v1", "workspace-status-v1", "state-resources-v1"])
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    @Test func anOlderDaemonSaysWhyInstead() {
        let services = Self.services(capabilities: ["state-resources-v1"])
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) != nil, "\(id) runs without its capability")
        }
    }

    /// Set Workspace Status offers classic's lanes and Automatic, under their wire names.
    @Test func setWorkspaceStatusOffersTheClassicLanes() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "palette.workspaceStatus" })
        let status = try #require(descriptor.arguments.first { $0.name == "status" })
        guard case .enumeration(let cases) = status.kind else {
            Issue.record("status is not a choice")
            return
        }
        #expect(cases.map(\.value) == ["auto", "todo", "working", "needs-attention", "review", "done"])
    }

    @Test func theRowShowsTheDescriptionWithoutALeadStatusGlyph() throws {
        let row = try Self.row(extra: #"{"description":"Ship the release\n- changelog","task_status":"done"}"#)
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.detail == "Ship the release", "the description's first line leads the second line")
        #expect(content.icon == nil, "task status is already represented by the trailing status dots")

        let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Date())
        #expect(card.facts.first { $0.kind == "description" }?.text == "Ship the release\n- changelog")
        #expect(card.facts.contains { $0.kind == "taskStatus" && !$0.text.isEmpty })
    }

    @Test func aWorkspaceWithNeitherStaysAOneLineRowWithoutAGlyph() throws {
        let row = try Self.row(extra: "{}")
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.detail == nil)
        #expect(content.icon == nil)
        let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Date())
        #expect(!card.facts.contains { $0.kind == "description" || $0.kind == "taskStatus" })
    }

    /// A user icon keeps its slot; the lane still shows on the hover card. An unknown lane from a
    /// newer daemon reads as automatic.
    @Test func aUserIconKeepsItsSlotAndAnUnknownLaneIsAutomatic() throws {
        let row = try Self.row(extra: #"{"task_status":"working"}"#, icon: "star.fill")
        #expect(WorkspaceRowContent(row, preferences: .defaults).icon == .symbol("star.fill"))
        let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Date())
        #expect(card.facts.contains { $0.kind == "taskStatus" })
        let unknown = try Self.row(extra: #"{"task_status":"someday"}"#)
        #expect(WorkspaceRowContent(unknown, preferences: .defaults).icon == nil)
    }
}
