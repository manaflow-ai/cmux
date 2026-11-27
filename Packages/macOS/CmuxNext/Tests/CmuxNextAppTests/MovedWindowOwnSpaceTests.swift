import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-11: "Did you open it in a new window? Also we were saying before that we wanted the different windows
/// to be accessible through spaces, and it's essentially all the same window in a way if you want it to be. ... Wait,
/// why does it say default in another window?" Content moved into a new window opened on the space it left, so two
/// windows showed Default. Like New Window (spaces-overhaul-DESIGN.md rule 3), the moved window takes a space of its
/// own: the workspace is pinned there, the window shows it, and the window it left keeps its space.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct MovedWindowOwnSpaceTests {
    @Test func aWorkspaceMovedToANewWindowGetsASpaceOfItsOwn() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            let workspace = try await MoveToNewWindowTests.newWorkspace(services)
            let source = try #require(services.windows.registry.value.owner(of: workspace.id))
            let sourceSpace = try #require(services.windows.states[source]?.profileID)
            let spaces = services.machines.local.store.profileIDs.count
            #expect(services.registry.perform("moveWorkspaceToNewWindow", invocation: MoveToNewWindowTests.on(.workspace, workspace.id)))
            @MainActor func moved() -> WindowState? {
                services.windows.registry.value.owner(of: workspace.id).flatMap { $0 == source ? nil : services.windows.states[$0] }
            }
            try await PinnedPageTests.until({ moved().map { $0.profileID != sourceSpace } == true },
                                            report: { "the moved window shows \(moved()?.profileID.rawValue ?? "-"), the source \(sourceSpace.rawValue)" })
            let window = try #require(moved())
            #expect(services.machines.local.store.profileIDs.count == spaces + 1)
            #expect(window.workspaceID == workspace.id)
            #expect(services.windows.states[source]?.profileID == sourceSpace)
            // No two open windows show one space.
            let shown = services.windows.registry.value.openWindows.compactMap { services.windows.states[$0.id]?.profileID }
            #expect(Set(shown).count == shown.count)
        }
    }
}
