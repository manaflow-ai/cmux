import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

@MainActor
struct SidebarJSRuntimeTests {
    @Test func buildsRetainedScene() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => VStack({ spacing: 8 }, [
            Text("Hello").font("headline"),
            Divider(),
        ]))
        """)
        #expect(ok)
        #expect(runtime.errorMessage == nil)
        let root = runtime.store.rootId.flatMap { runtime.store.node($0) }
        #expect(root?.type == "vstack")
        #expect(root?.double("spacing") == 8)
        let first = root?.children.first.flatMap { runtime.store.node($0) }
        #expect(first?.string("text") == "Hello")
        #expect(first?.string("font") == "headline")
    }

    @Test func reactivePropUpdatesOnlyOnDataChange() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => Text(() => "count: " + (data.count() ?? 0)))
        """)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "count: 0")
        runtime.updateData(key: "count", value: .int(5))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
        // An unrelated key leaves the prop untouched.
        runtime.updateData(key: "other", value: .string("x"))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
    }

    @Test func keyedReconcileKeepsRowIdentityAcrossReorder() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let before = try! #require(runtime.store.node(rootId)?.children)
        #expect(before.count == 2)

        // Reorder: identical node ids, swapped order (no remount).
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
            .object(["id": .string("a"), "title": .string("A")]),
        ]))
        let after = try! #require(runtime.store.node(rootId)?.children)
        #expect(after == before.reversed())

        // Removal disposes the row's nodes.
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let remaining = try! #require(runtime.store.node(rootId)?.children)
        #expect(remaining.count == 1)
        #expect(runtime.store.node(before[0]) == nil)
    }

    @Test func rowContentUpdatesInPlace() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("old")]),
        ]))
        let rowId = try! #require(runtime.store.node(rootId)?.children.first)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("new")]),
        ]))
        #expect(runtime.store.node(rootId)?.children.first == rowId)
        #expect(runtime.store.node(rowId)?.string("text") == "new")
    }

    @Test func buttonTapRunsCmuxCommand() {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Button("Select", () => cmux("workspace.select", { workspace_id: "w1" })))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        #expect(captured == [.cmux(method: "workspace.select", params: ["workspace_id": "w1"])])
    }

    @Test func reorderableCarriesItemKeysAndMoveHandler() {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Reorderable(
            {
                items: () => data.items() ?? [],
                key: (w) => w.id,
                onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index: index }),
            },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        #expect(runtime.store.node(rootId)?.string("itemKeys") == #"["a","b"]"#)
        runtime.dispatchEvent(nodeId: rootId, event: "move", payload: ["id": "a", "index": 1])
        #expect(captured == [.cmux(method: "workspace.reorder", params: ["workspace_id": "a", "index": "1"])])
    }

    @Test func programErrorSurfacesWithLine() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "sidebar(() => notAFunction())")
        #expect(!ok)
        #expect(runtime.errorMessage?.contains("line") == true)
    }

    @Test func missingRootIsAnError() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "const x = 1")
        #expect(!ok)
        #expect(runtime.errorMessage != nil)
    }

    @Test func validateAcceptsGoodProgramAndRejectsBadOne() {
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => Text(\"ok\"))",
            state: CustomSidebarValidator.defaultDataContext
        ) == nil)
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => missing())",
            state: [:]
        ) != nil)
    }

    @Test func watchdogTerminatesRunawayProgram() {
        // The hard limit resolves a non-public JSC symbol; skip when absent
        // (the test would otherwise hang forever).
        guard JSWatchdog.install(on: JSContextHolder.make(), seconds: 0.05) else { return }
        let message = SidebarJSRuntime.validate(source: "while (true) {}", state: [:])
        #expect(message != nil)
    }
}

import JavaScriptCore

enum JSContextHolder {
    static func make() -> JSContext { JSContext()! }
}
