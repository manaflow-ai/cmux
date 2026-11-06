import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Moving one tab to a space must leave its siblings in their original workspace and space.
/// Exercise the registry path used by both CLI and MCP, against a same-tree daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabMoveToSpaceTests {
    @Test func movingOneTabLeavesItsSiblingAndSourceMembershipAlone() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.machines.local.store
            let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.newTab(in: pane.handle)
            try await PinnedPageTests.until({ pane.tabs.count >= 2 }, report: { "\(pane.tabs.count) tabs" })
            let moved = try #require(pane.tabs.first)
            let sibling = try #require(pane.tabs.last)
            let source = try #require(services.workspaceID(ofTab: moved.id))
            let sourceQualified = try #require(WindowProfiles.qualified(source, machines: services.machines))
            let originalPin = WindowProfiles.membership(services.machines)?.pinned(sourceQualified)
            let target = try await connection.createProfile(name: "Tab destination")
            try await PinnedPageTests.until({ store.profile(target.id) != nil }, report: { "destination not mirrored" })
            let window = try #require(services.windows.active)
            let shownSpace = window.state.profileID

            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: moved.id),
                                              arguments: ["space": .string(target.id.rawValue)], origin: .cli)
            let work = services.registry.capturingWork {
                #expect(services.registry.perform("tab.moveToSpace", invocation: invocation))
            }
            try #require(!work.isEmpty, "the caller must await both the promotion and the space assignment")
            for task in work {
                let failure = await task.value
                #expect(failure == nil, "\(String(describing: failure))")
            }
            // The direct registry harness has no control-socket scope to drain daemon echoes.
            try await PinnedPageTests.until({
                guard let destination = services.workspaceID(ofTab: moved.id), destination != source,
                      let qualified = WindowProfiles.qualified(destination, machines: services.machines) else { return false }
                return WindowProfiles.membership(services.machines)?.pinned(qualified) == target.id
            }, report: { "the promoted tab and its space assignment were not mirrored" })
            let destination = try #require(services.workspaceID(ofTab: moved.id))
            #expect(destination != source, "moving a tab reassigned its whole source workspace")
            #expect(services.workspaceID(ofTab: sibling.id) == source, "the sibling moved with the selected tab")
            let destinationQualified = try #require(WindowProfiles.qualified(destination, machines: services.machines))
            #expect(WindowProfiles.membership(services.machines)?.pinned(destinationQualified) == target.id)
            #expect(WindowProfiles.membership(services.machines)?.pinned(sourceQualified) == originalPin)
            #expect(window.state.profileID == shownSpace, "a CLI move switched the person's space")
        }
    }

    @Test func anUnknownSpaceRefusesBeforeMovingTheTab() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let tab = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
            let source = services.workspaceID(ofTab: tab.id)
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id),
                                              arguments: ["space": .string("missing-\(UUID().uuidString)")], origin: .cli)
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("tab.moveToSpace", invocation: invocation)
                }
            }
            #expect(refusal != nil)
            #expect(work.isEmpty)
            #expect(services.workspaceID(ofTab: tab.id) == source)
        }
    }
}
