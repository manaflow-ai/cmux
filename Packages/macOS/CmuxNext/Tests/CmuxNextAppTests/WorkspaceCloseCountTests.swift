import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-11-10 (f15/f16): "closing workspaces with cmd shift w feels kinda slow". One Close Workspace does
/// work O(shown + changed): what it walks in its key turn is the same in the person's session (826 workspaces,
/// `SessionFixtureSize.real`) as in one of 60 (CLAUDE.md "Go past Chrome": a local model change is O(changed items),
/// never O(session)). Each test drives the close the key runs (`InstantClose.begin`, the turn of `closeWorkspace`) in
/// a whole window and reads the window registry's `WorkspaceCloseWork` (`WindowRegistryStore.closeWork`). The close is then ended (`ClosingWorkspaces.end`), as the daemon's
/// answer ends it: `ClosingWorkspaces.shared` is one set for the whole test process.
///
/// Sizes: `large` always, and each other size `CMUX_TEST_SESSION_SIZES` names (the 826 arm runs on a mini, never by
/// default: `SessionFixtureSize`). The counts of every size run must be equal, and each has a bound with no session
/// size in it, so `large` alone fails too when a count follows the session.
///
///     CMUX_TEST_SESSION_SIZES=large,real swift test --filter WorkspaceCloseCountTests
@MainActor @Suite(.serialized) struct WorkspaceCloseCountTests {
    typealias Fixture = LargeSessionWindowFixture

    static let sizes: [SessionFixtureSize] = [.large] + SessionFixtureSize.arms.filter { $0 != .large }

    /// The frame of a second window.
    static let secondFrame = CGRect(x: 240, y: 240, width: 1200, height: 800)

    /// Closes the workspace a one-window session shows, with one other workspace parked (as after any switch).
    /// Returns what the close's turn walked and how many contents the window had parked at the press.
    static func closeShown(_ size: SessionFixtureSize) async throws -> (work: WorkspaceCloseWork, parked: Int) {
        try await Fixture.withController(size) { _, controller in
            let first = try #require(controller.state.workspaceID)
            controller.showWorkspace(requested: Fixture.key(1))
            await Fixture.drainMain()
            let shown = try #require(controller.state.workspaceID)
            try #require(shown != first && controller.parked[first] != nil, "fixture: the first workspace is not parked")
            let parked = controller.parked.count
            _ = SidebarView.perfCounters(reset: true)
            let registry = controller.services.windows.registry
            _ = registry.takeCloseWork()
            let hidden = InstantClose.begin([shown], in: controller.state.id, windows: controller.services.windows)
            let work = registry.takeCloseWork()
            let sidebar = SidebarView.perfCounters(reset: true)
            ClosingWorkspaces.shared.end(shown, refused: false, in: nil)
            // Not checked here (the rows pass and the pick still read every row of the window that closes one): printed
            // for the owner of the close path, who reads them at each size.
            let rows = ["section_sets", "rebuilds", "row_maps", "order_builds", "layout_rows", "list_reloads"].map { "\($0) \(sidebar[$0] ?? 0)" }
            print("WorkspaceCloseCount \(size.rawValue): \(work); sidebar: \(rows.joined(separator: ", "))")
            #expect(hidden == [shown], "\(size.rawValue): the close hid \(hidden)")
            #expect(controller.state.workspaceID != shown, "\(size.rawValue): the window still shows the closed workspace")
            #expect(controller.parked[first] != nil || controller.state.workspaceID == first,
                    "\(size.rawValue): the close tore down a parked workspace its window lists")
            return (work, parked)
        }
    }

    /// The window finds the parked contents that left it by asking for each parked one, not by listing every
    /// workspace of the window: the ids `showWorkspace` reads per run are the parked contents, at any session size.
    @Test(.timeLimit(.minutes(5)))
    func aCloseReadsNoListOfTheWindowsWorkspacesToShowTheNext() async throws {
        var read: [String: Int] = [:], calls: [String: Int] = [:]
        for size in Self.sizes {
            let (work, parked) = try await Self.closeShown(size)
            read[size.rawValue] = work.shownIDs
            calls[size.rawValue] = work.showCalls
            #expect(work.showCalls >= 1, "\(size.rawValue): the close showed no workspace: \(work)")
            // Each run reads the parked contents: the ones parked at the press, and the closed one once it is parked.
            #expect(work.shownIDs <= work.showCalls * (parked + 1),
                    "\(size.rawValue): showWorkspace read \(work.shownIDs) ids in \(work.showCalls) runs, with \(parked) parked: \(work)")
        }
        #expect(Set(read.values).count == 1, "ids showWorkspace read per close grow with the session: \(read)")
        #expect(Set(calls.values).count == 1, "showWorkspace runs per close differ by session: \(calls)")
    }

    /// Closes the workspace a second window of 3 workspaces shows; the first window lists all the others.
    static func closeInSecondWindow(_ size: SessionFixtureSize) async throws -> WorkspaceCloseWork {
        try await Fixture.withController(size) { _, controller in
            let windows = controller.services.windows
            let second = try #require(windows.openWindow(workspaces: (1...3).map(Fixture.key), frame: secondFrame))
            defer { second.teardown(); second.window?.close() }
            for _ in 0..<50 where second.workspaceContent == nil { await Fixture.drainMain() }
            await Fixture.drainMain()
            try #require(windows.registry.members(of: second.state.id).count == 3, "fixture: the second window's workspaces")
            try #require(windows.registry.members(of: controller.state.id).count == size.workspaces - 3, "fixture: the first window's workspaces")
            let shown = try #require(second.state.workspaceID)
            let other = controller.state.workspaceID
            _ = windows.registry.takeCloseWork()
            let hidden = InstantClose.begin([shown], in: second.state.id, windows: windows)
            let work = windows.registry.takeCloseWork()
            ClosingWorkspaces.shared.end(shown, refused: false, in: nil)
            #expect(hidden == [shown], "\(size.rawValue): the close hid \(hidden)")
            #expect(second.state.workspaceID != shown, "\(size.rawValue): the window still shows the closed workspace")
            #expect(controller.state.workspaceID == other, "\(size.rawValue): the close moved another window's selection")
            return work
        }
    }

    /// A close repairs the selection of the window that lists the closed workspace, and of no other: the other
    /// window's list (the rest of the session) is not read.
    @Test(.timeLimit(.minutes(5)))
    func aCloseRepairsTheSelectionOfItsWindowOnly() async throws {
        var repaired: [String: Int] = [:]
        for size in Self.sizes {
            let work = try await Self.closeInSecondWindow(size)
            repaired[size.rawValue] = work.repairedIDs
            #expect(work.repairedWindows == 1, "\(size.rawValue): the close repaired \(work.repairedWindows) windows: \(work)")
            #expect(work.repairedIDs == 3, "\(size.rawValue): the repair read \(work.repairedIDs) workspace ids, its window lists 3: \(work)")
        }
        #expect(Set(repaired.values).count == 1, "ids the selection repair reads per close grow with the session: \(repaired)")
    }

    /// The other half of the parked check: a parked workspace that moved to another window is torn down at the next
    /// show, and a parked one the window still lists stays. It passes before the change too: it keeps that behaviour.
    @Test(.timeLimit(.minutes(2)))
    func aParkedWorkspaceThatMovedToAnotherWindowGoesAndAListedOneStays() async throws {
        try await Fixture.withController(.large) { _, controller in
            let windows = controller.services.windows
            let first = try #require(controller.state.workspaceID)
            controller.showWorkspace(requested: Fixture.key(1))
            await Fixture.drainMain()
            let moved = try #require(controller.state.workspaceID)
            controller.showWorkspace(requested: Fixture.key(2))
            await Fixture.drainMain()
            let kept = try #require(controller.state.workspaceID)
            controller.showWorkspace(requested: first)
            await Fixture.drainMain()
            try #require(Set([first, moved, kept]).count == 3 && controller.parked[moved] != nil && controller.parked[kept] != nil,
                         "fixture: two workspaces are parked")
            let second = try #require(windows.openWindow(workspaces: [moved], frame: Self.secondFrame))
            defer { second.teardown(); second.window?.close() }
            await Fixture.drainMain()
            try #require(windows.registry.members(of: second.state.id) == [moved], "fixture: the second window took the workspace")
            controller.showWorkspace(requested: controller.state.workspaceID)
            #expect(controller.parked[moved] == nil, "a parked workspace that moved to another window stayed parked")
            #expect(controller.parked[kept] != nil, "a parked workspace the window lists was torn down")
        }
    }
}
