import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-07, of a relaunch: "Like, it was already loaded, and then it flickered." The saved sidebar drew each
/// row from its title and icon alone, so a row with a second line, a status block or a Done status came back one
/// line tall and outside the Done fold; the live tree then grew and moved every row in one unanimated reload. A
/// restored row now has the height and the fold its live row has, so the live tree's arrival moves no row.
@MainActor @Suite
struct SidebarRestoredRowHeightTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The row through a saved snapshot and back, as a relaunch reads it.
    private static func restored(_ row: SidebarWorkspace) throws -> SidebarWorkspace {
        let data = try JSONEncoder().encode(SidebarWorkspaceSnapshot(row: row))
        return try JSONDecoder().decode(SidebarWorkspaceSnapshot.self, from: data).restoredRow
    }

    private static func height(_ ws: SidebarWorkspace, _ preferences: WorkspaceRowPreferences) -> CGFloat {
        SidebarLayoutMetrics.standard.height(for: WorkspaceRowContent(ws, preferences: preferences, now: now))
    }

    private static func expandedHeight(_ ws: SidebarWorkspace) -> CGFloat {
        SidebarLayoutMetrics.standard.expanded.height(for: WorkspaceRowContent(expanded: ws, now: now))
    }

    /// The default row (`WorkspaceRowPreferences.defaults`) shows progress: a reported progress label and its bar.
    private static func building() -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("build"), title: "build", progress: SidebarProgress(value: 0.4))
        ws.reported = SidebarWorkspaceStatus(progressLabel: "Compiling 12 of 30")
        return ws
    }

    /// A row with a second line (folder and branch), five reported entries with a log line, and a Done status.
    private static func reporting() -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("agent"), title: "agent", directory: "~/src/app", branch: "main",
                                  pullRequest: "#42", lastActivity: now.addingTimeInterval(-60), kind: .harness)
        ws.reported = SidebarWorkspaceStatus(
            entries: (1 ... 5).map { SidebarWorkspaceStatus.Entry(key: "step\($0)", text: "Step \($0)") },
            log: SidebarWorkspaceStatus.LogLine(level: .warning, text: "Retrying the fetch"),
            progressLabel: "Halfway")
        ws.progress = SidebarProgress(value: 0.5)
        ws.workspaceDescription = "Ship the fix\nmore notes"
        ws.taskStatus = .done
        return ws
    }

    /// Every second-line and status element on, as a person may set `sidebar.workspaceRow`.
    private static let detailed = WorkspaceRowPreferences(base: WorkspaceRowElements(
        shown: WorkspaceRowElements.standard.shown.union([.directory, .branch, .agentStatus, .log, .lastActivity])))

    @Test func aRestoredRowHasItsLiveHeightUnderTheDefaults() throws {
        for live in [Self.building(), Self.reporting(), SidebarWorkspace(id: WorkspaceID("quiet"), title: "quiet")] {
            let restored = try Self.restored(live)
            #expect(Self.height(restored, .defaults) == Self.height(live, .defaults), "\(live.id.rawValue)")
        }
    }

    @Test func aRestoredRowHasItsLiveHeightWithEveryLineOn() throws {
        for live in [Self.building(), Self.reporting()] {
            let restored = try Self.restored(live)
            #expect(Self.height(restored, Self.detailed) == Self.height(live, Self.detailed), "\(live.id.rawValue)")
            #expect(Self.expandedHeight(restored) == Self.expandedHeight(live), "\(live.id.rawValue)")
        }
    }

    @Test func aRestoredRowKeepsItsTaskStatus() throws {
        let live = Self.reporting()
        let restored = try Self.restored(live)
        #expect(restored.taskStatus == live.taskStatus)
        #expect(restored.rowState == .stale)
    }

    @Test func anOlderSnapshotStillReads() throws {
        let json = #"{"id":"w","machineID":"local","title":"w","kind":"terminal"}"#
        let row = try JSONDecoder().decode(SidebarWorkspaceSnapshot.self, from: Data(json.utf8)).restoredRow
        #expect(row.title == "w")
        #expect(row.reported == nil)
        #expect(row.taskStatus == nil)
    }
}
