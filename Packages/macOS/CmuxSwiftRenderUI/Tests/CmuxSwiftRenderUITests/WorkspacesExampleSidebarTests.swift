import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Foundation
import Testing

/// Behavior of the bundled `workspaces.js` custom sidebar template.
@MainActor
struct WorkspacesExampleSidebarTests {
    /// Actions dispatch one main-queue turn after the event; suspend so the
    /// queued dispatch runs before asserting.
    private func pumpActions() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func examplesDirectory() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Examples/CustomSidebars", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("Examples/CustomSidebars", isDirectory: true)
    }

    private static func workspace(_ id: String, _ title: String) -> SwiftValue {
        .object([
            "id": .string(id),
            "title": .string(title),
            "selected": .bool(false),
            "unread": .int(0),
            "pinned": .bool(false),
        ])
    }

    /// Ids of every `xmark` close glyph currently in the scene, in tree order.
    /// Each rendered workspace row has exactly one.
    private func closeButtonIds(in store: SceneStore) -> [String] {
        var found: [String] = []
        var stack = store.rootId.map { [$0] } ?? []
        while let id = stack.popLast() {
            guard let node = store.node(id) else { continue }
            if node.type == "image", node.string("systemName") == "xmark" {
                found.append(id)
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// A refused `workspace.close` (the workspace has a running process and
    /// needs confirmation) leaves the workspace in the data context. Its row
    /// must stay visible: if the sidebar hides it ahead of the data, the
    /// workspace is still open and still counted by Cmd+1…9, but there is no
    /// row left to reach it from.
    @Test func closeTapKeepsRowUntilDataDropsWorkspace() async throws {
        let source = try String(
            contentsOf: examplesDirectory().appendingPathComponent("workspaces.js"),
            encoding: .utf8
        )
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        #expect(runtime.start(source: source))
        #expect(runtime.errorMessage == nil)

        let both: SwiftValue = .array([Self.workspace("w1", "One"), Self.workspace("w2", "Two")])
        runtime.updateData(key: "workspaces", value: both)
        let closeButtons = closeButtonIds(in: runtime.store)
        #expect(closeButtons.count == 2)

        runtime.dispatchEvent(nodeId: try #require(closeButtons.first), event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.close", params: ["workspace_id": "w1"])])

        // The close was refused: the next refresh still lists w1.
        runtime.updateData(key: "workspaces", value: both)
        #expect(closeButtonIds(in: runtime.store).count == 2)

        // Once cmux actually closes w1, its row goes away.
        runtime.updateData(key: "workspaces", value: .array([Self.workspace("w2", "Two")]))
        #expect(closeButtonIds(in: runtime.store).count == 1)
    }
}
