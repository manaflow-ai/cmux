import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// p03-rendering-096 through the real switch: `WindowManager.show(workspaceID:in:)` parks the outgoing
/// workspace's controller, unparks the incoming one, resumes its panes and installs their content
/// (`PaneContentView.install`/`retire`). A switch back to a recently hidden workspace moves no workspace,
/// pane or terminal view into or out of the window. Three workspaces with a terminal pane each, against a
/// same-tree cmux-tui daemon; the unit form is HiddenWorkspaceStaysInWindowTests.
/// skip-owner: PL-switch; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HiddenWorkspaceSwitchKeepsPanesInWindowTests {
    /// A hidden, zero-size child that counts the times its ancestors enter or leave a window.
    final class WindowMoves: NSView {
        private(set) var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    /// What a workspace has on screen once shown: its controller, its panes and each pane's content.
    private struct Mounted: Equatable {
        let controller: ObjectIdentifier
        let panes: Set<ObjectIdentifier>
        let contents: Set<ObjectIdentifier>
    }

    private static func mounted(_ content: WorkspaceContentController) -> Mounted {
        let panes = Array(content.panes.values)
        return Mounted(controller: ObjectIdentifier(content), panes: Set(panes.map { ObjectIdentifier($0) }),
                       contents: Set(panes.compactMap { $0.view.content.map { ObjectIdentifier($0) } }))
    }

    @Test func switchingBackToHiddenWorkspacesMovesNoPaneContentIntoTheWindow() async throws {
        try await PinnedPageTests.withApp { services, _ in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let window = try #require(services.windows.active)
            let shell = try #require(window.window)
            let host = window.root.contentHost
            let a = try #require(window.state.workspaceID)
            let b = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "hidden-b"), into: window.state.id)
            let c = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: NSTemporaryDirectory(), name: "hidden-c"), into: window.state.id)

            @MainActor func shown(_ id: String) -> WorkspaceContentController? {
                guard let content = window.content, content.workspace.id == id, !content.panes.isEmpty,
                      content.panes.values.allSatisfy({ $0.view.content != nil }) else { return nil }
                return content
            }
            @MainActor func describe() -> String {
                let content = window.content
                return "window shows \(window.state.workspaceID ?? "nil"), mounted \(content?.workspace.id ?? "nil") with "
                    + "\(content?.panes.count ?? 0) panes, parked \(window.parked.keys.sorted())"
            }
            @MainActor func show(_ id: String) async throws -> WorkspaceContentController {
                services.windows.show(workspaceID: id, in: window.state)
                try await PinnedPageTests.until({ shown(id) != nil }, within: .seconds(30), report: describe)
                return try #require(shown(id))
            }

            // Each workspace shows once, so its view, panes and terminals are in the window.
            var mounted: [String: Mounted] = [:]
            var probes: [WindowMoves] = []
            for id in [a, b, c] {
                let content = try await show(id)
                mounted[id] = Self.mounted(content)
                var observed: [NSView] = [content.contentView]
                for pane in content.panes.values {
                    observed.append(pane.view)
                    if let shownContent = pane.view.content { observed.append(shownContent) }
                }
                for view in observed {
                    let probe = WindowMoves(frame: .zero)
                    probe.isHidden = true
                    view.addSubview(probe)
                    probes.append(probe)
                }
            }
            let entered = probes.map(\.moves)
            #expect(entered.allSatisfy { $0 == 1 }, "each probe enters the window once, when added: \(entered)")

            for id in [a, b, a, c, b, a] {
                let previous = window.content
                let content = try await show(id)
                #expect(Self.mounted(content) == mounted[id], "switching to \(id) mounted a new controller, pane or content: \(describe())")
                #expect(content.contentView.window === shell && !content.contentView.isHidden)
                if let previous, previous !== content {
                    #expect(previous.contentView.isHidden && previous.contentView.superview === host,
                            "the outgoing workspace hides in the main pane: \(describe())")
                }
            }
            let moved = zip(probes.map(\.moves), entered).map { $0 - $1 }
            #expect(moved.allSatisfy { $0 == 0 }, "switches back to hidden workspaces moved views into or out of the window: \(moved)")
            #expect([b, c].allSatisfy { window.parked[$0]?.contentView.superview === host }, "hidden workspaces stay in the main pane")
        }
    }
}
