import AppKit
import Testing
@testable import CmuxNextAgentPane

/// The origin lead's review of the main-actor hop for the gesture record: the decision must be made
/// on the state at event time, in the monitor, before AppKit dispatches the event. A key that a
/// native responder handles and that moves focus into the web view, or a click whose dispatch moves
/// the web view under the pointer, is not a gesture in the pane. The tests call the decision with
/// the test window (a synthesized event cannot resolve its window), then simulate the dispatch.
@MainActor
@Suite(.serialized) struct AgentPaneGestureMonitorTests {
    struct Rig {
        let model: AgentPaneModel
        let view: AgentPaneView
        let window: NSWindow
        let field: NSTextField
        var gestures: AgentPaneUserGestures { model.transport.gestures }
    }

    func rig() throws -> Rig {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let view = try #require(AgentPaneView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 420, y: 500, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        window.contentView?.layoutSubtreeIfNeeded()
        return Rig(model: model, view: view, window: window, field: field)
    }

    /// Lets any task the monitor queued run.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    func key(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\t",
                                      charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    }

    func click(_ window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: 1))
    }

    /// The real path end to end: a keyDown NSEvent (Return, as when the user sends a prompt) goes
    /// through `NSApplication.sendEvent`, whose local monitors run before any dispatch. The pane's
    /// monitor records the credit, and the prompt frame's gesture check uses it once.
    @Test func aRealKeyDownThroughTheAppRecordsTheGestureThePromptUses() async throws {
        let app = NSApplication.shared
        let rig = try rig()
        defer { rig.view.close(); rig.window.close() }
        func returnKey() throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: rig.window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        // Control: the same key while a native field has the keyboard is not the pane's gesture.
        rig.window.makeFirstResponder(rig.field)
        app.sendEvent(try returnKey())
        await settle()
        #expect(!rig.gestures.isAvailable, "the key went to a native field")

        rig.window.makeFirstResponder(rig.view.webView)
        app.sendEvent(try returnKey())
        await settle()
        #expect(rig.gestures.isAvailable, "a key with the page focused is the user's gesture")
        #expect(rig.gestures.consume(), "the prompt frame uses the credit")
        #expect(!rig.gestures.consume(), "once")
    }

    @Test func aKeyThatMovesFocusIntoTheWebViewIsNoGesture() async throws {
        let rig = try rig()
        defer { rig.view.close(); rig.window.close() }
        rig.window.makeFirstResponder(rig.field)
        rig.view.judge(try key(rig.window), eventWindow: rig.window)
        // AppKit dispatches the key to the native field, which moves focus into the web view.
        rig.window.makeFirstResponder(rig.view.webView)
        await settle()
        #expect(!rig.gestures.isAvailable, "the key went to a native responder at event time")
        // Control: a key while the web view has focus is a gesture.
        rig.view.judge(try key(rig.window), eventWindow: rig.window)
        await settle()
        #expect(rig.gestures.isAvailable)
    }

    @Test func aClickWhoseDispatchMovesTheWebViewUnderThePointIsNoGesture() async throws {
        let rig = try rig()
        defer { rig.view.close(); rig.window.close() }
        let outside = NSPoint(x: 600, y: 200)
        rig.view.judge(try click(rig.window, at: outside), eventWindow: rig.window)
        // The click's dispatch moves the web view under the point.
        rig.view.frame = NSRect(x: 400, y: 0, width: 400, height: 400)
        rig.window.contentView?.layoutSubtreeIfNeeded()
        await settle()
        #expect(!rig.gestures.isAvailable, "the click was outside the web view at event time")
        // Control: a click inside the web view is a gesture.
        rig.view.judge(try click(rig.window, at: NSPoint(x: 600, y: 200)), eventWindow: rig.window)
        await settle()
        #expect(rig.gestures.isAvailable)
    }
}
