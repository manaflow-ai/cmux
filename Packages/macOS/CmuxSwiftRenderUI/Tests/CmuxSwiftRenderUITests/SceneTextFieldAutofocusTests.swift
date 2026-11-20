import AppKit
import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import SwiftUI
import Testing

/// A JS sidebar's `TextField` autofocuses on mount, so mounting one moves the
/// window's keyboard focus. Only the user may give the sidebar that focus: a
/// field mounted by a data update while the user types in a terminal would
/// otherwise take the keystrokes (passwords included) meant for the terminal
/// and hand them to the sidebar's `onEdit` handler.
///
/// Each test hosts the sidebar the way ``JSSidebarHostView`` does, beside a
/// stand-in terminal view in the same window, and drives it through the
/// engine's real data and event paths.
@MainActor
@Suite(.serialized)
struct SceneTextFieldAutofocusTests {
    /// Stands in for the terminal surface: a plain focusable view, like the
    /// Ghostty surface view.
    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    private struct Harness {
        let engine: JSSidebarEngine
        let window: NSWindow
        let terminal: TerminalStandIn
        let sidebar: NSView
        let source: String

        /// Pushes `data` through the same per-key diff the host view runs.
        func update(_ data: [String: SwiftValue]) {
            engine.sync(source: source, dataContext: data, dispatch: .noop)
        }

        /// Delivers a click to `nodeId` through the host's event sink.
        func tap(_ nodeId: String) {
            engine.eventSink.send(nodeId, "tap", [:])
        }

        func textFields() -> [NSTextField] {
            SceneTextFieldAutofocusTests.textFields(in: sidebar)
        }

        func hasFocus(_ view: NSView) -> Bool {
            guard let responder = window.firstResponder else { return false }
            if responder === view { return true }
            // A focused text field's first responder is its field editor.
            if let editor = responder as? NSText, editor.delegate === view as AnyObject { return true }
            return false
        }
    }

    private func host(_ source: String, data: [String: SwiftValue] = [:]) throws -> Harness {
        _ = NSApplication.shared
        let engine = JSSidebarEngine()
        engine.sync(source: source, dataContext: data, dispatch: .noop)
        #expect(engine.errorMessage == nil)
        let rootId = try #require(engine.rootId)
        let sidebar = NSHostingView(
            rootView: SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, engine.store)
                .environment(\.sceneEventSink, engine.eventSink)
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let terminal = TerminalStandIn(frame: NSRect(x: 240, y: 0, width: 400, height: 400))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        content.addSubview(sidebar)
        content.addSubview(terminal)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.orderBack(nil)
        sidebar.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(terminal))
        return Harness(engine: engine, window: window, terminal: terminal, sidebar: sidebar, source: source)
    }

    /// One turn of host work: the run loop (SwiftUI updates) and, by
    /// suspending, the main dispatch queue. The test itself runs as a
    /// main-queue job, so a nested run loop alone never drains the field's
    /// `DispatchQueue.main.async` focus hop.
    private func turn() async {
        spinRunLoop()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    /// Synchronous on purpose: `RunLoop.run(until:)` is unavailable directly
    /// in async code.
    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// Runs host turns until `condition` or a bounded deadline
    /// (deterministic test scaffolding, not runtime synchronization).
    private func pump(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            await turn()
        }
    }

    /// Runs a few host turns so a mounted field's deferred focus request
    /// (one plain async hop) has had its chance to run.
    private func settle() async {
        for _ in 0..<10 { await turn() }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
    }

    /// The reported attack: a data update mounts an invisible field while the
    /// user is typing in the terminal.
    @Test func fieldMountedByDataUpdateLeavesTerminalFocused() async throws {
        let harness = try host("""
        sidebar(() => VStack([
          Text("sessions"),
          ForEach({ items: () => data.fields() ?? [] }, () =>
            TextField("", { onEdit: (t) => log(t) }).opacity(0)
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        #expect(harness.textFields().isEmpty)

        harness.update(["fields": .array([.string("probe")])])
        await pump { !harness.textFields().isEmpty }
        let field = try #require(harness.textFields().first)
        await settle()

        #expect(harness.window.firstResponder === harness.terminal)
        #expect(!harness.hasFocus(field))
    }

    /// The legitimate case: the user clicks Rename (a button, double-click
    /// or menu item) and the editor that click mounts is ready to type into.
    @Test func fieldMountedByAClickTakesFocus() async throws {
        let harness = try host("""
        const [editing, setEditing] = signal(false);
        sidebar(() => VStack([
          Button("Rename", () => setEditing(true)),
          ForEach({ items: () => (editing() ? ["rename"] : []) }, () =>
            TextField("old name", { onSubmit: () => setEditing(false) })
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        let rootId = try #require(harness.engine.rootId)
        let buttonId = try #require(harness.engine.store?.node(rootId)?.children.first)

        harness.tap(buttonId)
        await pump { !harness.textFields().isEmpty }
        let field = try #require(harness.textFields().first)
        await pump { harness.hasFocus(field) }

        #expect(harness.hasFocus(field))
    }

    /// Focus already inside the sidebar (the user clicked into its search
    /// box) may move between that sidebar's own fields.
    @Test func fieldMountedWhileTheSidebarHasFocusTakesIt() async throws {
        let harness = try host("""
        sidebar(() => VStack([
          TextField("", { placeholder: "Search", autofocus: false }),
          ForEach({ items: () => data.fields() ?? [] }, () =>
            TextField("result", {})
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        await pump { !harness.textFields().isEmpty }
        let search = try #require(harness.textFields().first)
        await settle()
        #expect(harness.window.firstResponder === harness.terminal)

        #expect(harness.window.makeFirstResponder(search))
        #expect(harness.hasFocus(search))

        harness.update(["fields": .array([.string("result")])])
        await pump { harness.textFields().count == 2 }
        let result = try #require(harness.textFields().first { $0 !== search })
        await pump { harness.hasFocus(result) }

        #expect(harness.hasFocus(result))
    }

    /// `autofocus: false` keeps a field unfocused even when a click mounts it.
    @Test func autofocusFalseNeverTakesFocus() async throws {
        let harness = try host("""
        const [shown, setShown] = signal(false);
        sidebar(() => VStack([
          Button("Show", () => setShown(true)),
          ForEach({ items: () => (shown() ? ["search"] : []) }, () =>
            TextField("", { autofocus: false })
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        let rootId = try #require(harness.engine.rootId)
        let buttonId = try #require(harness.engine.store?.node(rootId)?.children.first)

        harness.tap(buttonId)
        await pump { !harness.textFields().isEmpty }
        await settle()

        #expect(harness.window.firstResponder === harness.terminal)
    }

    /// The click itself moved focus out of the sidebar (selecting a
    /// workspace focuses its terminal); the data update that follows mounts
    /// a hidden field within the click window. It must not take focus.
    @Test func clickThatMovesFocusAwayLetsNoLaterMountTakeIt() async throws {
        let harness = try host("""
        sidebar(() => VStack([
          Button("Select workspace", () => {}),
          ForEach({ items: () => data.fields() ?? [] }, () =>
            TextField("", { onEdit: (t) => log(t) }).opacity(0)
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        let newTerminal = TerminalStandIn(frame: NSRect(x: 240, y: 0, width: 400, height: 400))
        harness.window.contentView?.addSubview(newTerminal)
        let rootId = try #require(harness.engine.rootId)
        let buttonId = try #require(harness.engine.store?.node(rootId)?.children.first)

        harness.tap(buttonId)
        #expect(harness.window.makeFirstResponder(newTerminal))
        harness.update(["fields": .array([.string("probe")])])
        await pump { !harness.textFields().isEmpty }
        await settle()

        #expect(harness.window.firstResponder === newTerminal)
    }

    /// Same attack inside the click: its handler mounts the hidden field and
    /// the host's action then focuses a terminal before the field's focus
    /// hop runs.
    @Test func clickMountedFieldLosesItsGrantWhenFocusMoves() async throws {
        let harness = try host("""
        const [shown, setShown] = signal(false);
        sidebar(() => VStack([
          Button("Select workspace", () => setShown(true)),
          ForEach({ items: () => (shown() ? ["probe"] : []) }, () =>
            TextField("", { onEdit: (t) => log(t) }).opacity(0)
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        let newTerminal = TerminalStandIn(frame: NSRect(x: 240, y: 0, width: 400, height: 400))
        harness.window.contentView?.addSubview(newTerminal)
        let rootId = try #require(harness.engine.rootId)
        let buttonId = try #require(harness.engine.store?.node(rootId)?.children.first)

        harness.tap(buttonId)
        #expect(harness.window.makeFirstResponder(newTerminal))
        await pump { !harness.textFields().isEmpty }
        await settle()

        #expect(harness.window.firstResponder === newTerminal)
    }

    /// A click that leaves focus alone still authorizes only the fields its
    /// own handler created, not one a later data update mounts.
    @Test func clickDoesNotAuthorizeADataMountedField() async throws {
        let harness = try host("""
        sidebar(() => VStack([
          Button("Refresh", () => {}),
          ForEach({ items: () => data.fields() ?? [] }, () =>
            TextField("", { onEdit: (t) => log(t) }).opacity(0)
          ),
        ]))
        """)
        defer { harness.window.orderOut(nil) }
        let rootId = try #require(harness.engine.rootId)
        let buttonId = try #require(harness.engine.store?.node(rootId)?.children.first)

        harness.tap(buttonId)
        harness.update(["fields": .array([.string("probe")])])
        await pump { !harness.textFields().isEmpty }
        await settle()

        #expect(harness.window.firstResponder === harness.terminal)
    }

    /// A click authorizes one focus move, for a node its handler created,
    /// soon after it; typing and submits authorize none.
    @Test func clickAuthorizesOneFocusMoveWithinTheWindow() {
        _ = NSApplication.shared
        var clock = ContinuousClock.now
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let gate = SceneAutofocusGate(now: { clock }, windows: { [window] })
        for event in ["edit", "submit", "cancel", "move"] {
            gate.deliver(event) { gate.noteNodeCreated(event) }
            #expect(!gate.allowsFocus(nodeId: event, in: window), "\(event) must not authorize focus")
        }

        gate.deliver("tap") { gate.noteNodeCreated("rename") }
        gate.noteNodeCreated("later")
        #expect(!gate.allowsFocus(nodeId: "later", in: window))
        gate.deliver("tap") { gate.noteNodeCreated("rename") }
        #expect(gate.allowsFocus(nodeId: "rename", in: window))
        #expect(!gate.allowsFocus(nodeId: "rename", in: window))

        gate.deliver("doubletap") { gate.noteNodeCreated("rename") }
        clock = clock.advanced(by: SceneAutofocusGate.gestureWindow + .milliseconds(1))
        #expect(!gate.allowsFocus(nodeId: "rename", in: window))
    }
}
