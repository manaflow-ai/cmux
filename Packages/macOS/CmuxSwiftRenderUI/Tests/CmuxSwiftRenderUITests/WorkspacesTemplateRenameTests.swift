import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSwiftRenderUI

/// Inline rename in the bundled Workspaces template (`workspaces.js`) ends
/// when focus moves elsewhere in the sidebar or the selection changes, not
/// only on Return/Escape (#39077).
@MainActor
struct WorkspacesTemplateRenameTests {
    /// `SidebarJSRuntime` runs each `cmux(...)` action from
    /// `DispatchQueue.main.async`, in order. A marker queued after the event
    /// runs only once every action the event queued has run, so assertions
    /// after this see all of them, including "no rename was sent".
    private func drainQueuedActions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func templateSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(
                "CmuxSettings/Sources/CmuxSettings/Resources/CustomSidebarTemplates/workspaces.js"
            )
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        Issue.record("bundled workspaces.js template not found")
        return ""
    }

    private func start(selected: String) throws -> (SidebarJSRuntime, Box) {
        let runtime = SidebarJSRuntime()
        let box = Box()
        runtime.dispatch = SidebarActionDispatch { action in
            box.commands.append(contentsOf: action.commands)
        }
        let source = try templateSource()
        #expect(runtime.start(source: source))
        #expect(runtime.errorMessage == nil)
        seed(runtime, selected: selected)
        return (runtime, box)
    }

    private func seed(_ runtime: SidebarJSRuntime, selected: String) {
        runtime.updateData(key: "groups", value: .array([
            .object([
                "id": .string("g1"), "name": .string("Group One"), "anchorId": .string("w1"),
                "collapsed": .bool(false), "pinned": .bool(false),
            ]),
        ]))
        runtime.updateData(key: "workspaces", value: .array([
            .object(["id": .string("w1"), "title": .string("Anchor"), "group": .string("g1"),
                     "selected": .bool(selected == "w1"), "index": .int(0)]),
            .object(["id": .string("w2"), "title": .string("Member"), "group": .string("g1"),
                     "selected": .bool(selected == "w2"), "index": .int(1)]),
            .object(["id": .string("w3"), "title": .string("Loose"),
                     "selected": .bool(selected == "w3"), "index": .int(2)]),
        ]))
        runtime.updateData(key: "selectedId", value: .string(selected))
    }

    private func allNodes(_ runtime: SidebarJSRuntime) -> [SceneNode] {
        var out: [SceneNode] = []
        func walk(_ id: String) {
            guard let node = runtime.store.node(id) else { return }
            out.append(node)
            node.children.forEach(walk)
        }
        if let root = runtime.store.rootId { walk(root) }
        return out
    }

    private func texts(under node: SceneNode, _ runtime: SidebarJSRuntime) -> [String] {
        var out: [String] = []
        func walk(_ id: String) {
            guard let n = runtime.store.node(id) else { return }
            if let text = n.string("text") { out.append(text) }
            n.children.forEach(walk)
        }
        walk(node.id)
        return out
    }

    /// Outermost node with `prop` set whose subtree shows `text`.
    private func node(_ runtime: SidebarJSRuntime, _ prop: String, showing text: String) -> SceneNode? {
        allNodes(runtime).first { $0.bool(prop) && texts(under: $0, runtime).contains(text) }
    }

    private func editor(_ runtime: SidebarJSRuntime) -> SceneNode? {
        allNodes(runtime).first { $0.type == "textfield" }
    }

    private func renames(_ commands: [ActionCommand]) -> [ActionCommand] {
        commands.filter {
            guard case let .cmux(method, params) = $0 else { return false }
            return method == "workspace.group.rename" || params["action"] == "rename"
        }
    }

    @Test func clickingAnotherRowCommitsAndClosesGroupRename() async throws {
        let (runtime, box) = try start(selected: "w1")
        let header = try #require(node(runtime, "doubleTappable", showing: "Group One"))
        runtime.dispatchEvent(nodeId: header.id, event: "doubletap")
        let field = try #require(editor(runtime))
        runtime.dispatchEvent(nodeId: field.id, event: "edit", payload: ["text": "Renamed"])

        let other = try #require(node(runtime, "tappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: other.id, event: "tap")
        await drainQueuedActions()

        #expect(editor(runtime) == nil)
        #expect(renames(box.commands) == [
            .cmux(method: "workspace.group.rename", params: ["group_id": "g1", "name": "Renamed"]),
        ])
    }

    @Test func clickingAnotherRowWithoutTypingClosesWithoutRenaming() async throws {
        let (runtime, box) = try start(selected: "w3")
        let row = try #require(node(runtime, "doubleTappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: row.id, event: "doubletap")
        #expect(editor(runtime) != nil)

        let other = try #require(node(runtime, "tappable", showing: "Member"))
        runtime.dispatchEvent(nodeId: other.id, event: "tap")
        await drainQueuedActions()

        #expect(editor(runtime) == nil)
        #expect(renames(box.commands).isEmpty)
    }

    @Test func selectionChangeFromOutsideCancelsWorkspaceRename() async throws {
        let (runtime, box) = try start(selected: "w3")
        let row = try #require(node(runtime, "doubleTappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: row.id, event: "doubletap")
        let field = try #require(editor(runtime))
        runtime.dispatchEvent(nodeId: field.id, event: "edit", payload: ["text": "Typed"])

        seed(runtime, selected: "w2") // e.g. Cmd+2
        await drainQueuedActions()

        #expect(editor(runtime) == nil)
        #expect(renames(box.commands).isEmpty)
    }

    @Test func renameCancelledBySelectionChangeCanBeReopened() throws {
        let (runtime, _) = try start(selected: "w3")
        let row = try #require(node(runtime, "doubleTappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: row.id, event: "doubletap")
        #expect(editor(runtime) != nil)

        seed(runtime, selected: "w2")
        seed(runtime, selected: "w3")

        let again = try #require(node(runtime, "doubleTappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: again.id, event: "doubletap")
        #expect(editor(runtime) != nil)
    }

    @Test func returnStillCommitsAndEscapeStillCancels() async throws {
        let (runtime, box) = try start(selected: "w3")
        let row = try #require(node(runtime, "doubleTappable", showing: "Loose"))
        runtime.dispatchEvent(nodeId: row.id, event: "doubletap")
        let field = try #require(editor(runtime))
        runtime.dispatchEvent(nodeId: field.id, event: "submit", payload: ["text": "ByReturn"])
        await drainQueuedActions()
        #expect(editor(runtime) == nil)
        #expect(renames(box.commands) == [
            .cmux(method: "workspace.action", params: ["action": "rename", "workspace_id": "w3", "title": "ByReturn"]),
        ])

        let renamed = try #require(node(runtime, "doubleTappable", showing: "ByReturn"))
        runtime.dispatchEvent(nodeId: renamed.id, event: "doubletap")
        let again = try #require(editor(runtime))
        runtime.dispatchEvent(nodeId: again.id, event: "cancel")
        #expect(editor(runtime) == nil)
    }
}

@MainActor
private final class Box {
    var commands: [ActionCommand] = []
}
