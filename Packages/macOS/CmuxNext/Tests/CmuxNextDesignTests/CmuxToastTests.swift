import AppKit
@testable import CmuxNextDesign
import Testing

/// R96 toasts: one shared presenter on the window overlay. At most three per
/// window (a fourth removes the oldest; the same id replaces), the newest at
/// the bottom; an action button; Cmd-Z runs the newest undo toast only when
/// the focused responder has nothing to undo; auto-dismiss on an injected
/// clock, paused while the pointer is on the toast.
@MainActor
struct CmuxToastTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    static func undo(_ id: String) -> CmuxToast {
        CmuxToast(id: id, message: "Hid \(id)", action: .undo(), duration: .seconds(5))
    }

    @Test func theStackKeepsThreeAndTheSameIDReplaces() {
        var stack = CmuxToastStack()
        #expect(stack.push(serial: 1, id: "a", undo: true).isEmpty)
        #expect(stack.push(serial: 2, id: "b", undo: false).isEmpty)
        #expect(stack.push(serial: 3, id: "c", undo: false).isEmpty)
        #expect(stack.push(serial: 4, id: "d", undo: false) == [1], "a fourth removes the oldest")
        #expect(stack.push(serial: 5, id: "c", undo: true) == [3], "the same id replaces")
        #expect(stack.serials == [2, 4, 5])
        #expect(stack.newestUndo == 5)
        stack.remove(5)
        #expect(stack.newestUndo == nil)
    }

    @Test func aToastEndsAfterItsDurationButNotWhileHovered() async {
        let clock = ManualClock()
        let host = CmuxToastHeadlessHost()
        let center = CmuxToastCenter(clock: clock, host: host)
        let window = Self.window()
        var reasons: [CmuxToastDismissReason] = []
        let handle = center.show(Self.undo("tab"), in: window)
        handle.onDismiss = { reasons.append($0) }
        await clock.sleepers(atLeast: 1)
        center.setHovered(true, handle)
        clock.advance(by: .seconds(10))
        for _ in 0..<50 { await Task.yield() }
        #expect(reasons.isEmpty, "the pointer on the toast keeps it")
        center.setHovered(false, handle)
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .seconds(5))
        // The timer's action hops to the main actor: yield until it ran (bounded).
        for _ in 0..<500 where reasons.isEmpty { await Task.yield() }
        #expect(reasons == [.timeout])
        #expect(host.slots.isEmpty)
    }

    @Test func theActionRunsOnceAndEndsTheToast() {
        let center = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        var actions = 0
        var reasons: [CmuxToastDismissReason] = []
        let handle = center.show(Self.undo("tab"), in: Self.window())
        handle.onAction = { actions += 1 }
        handle.onDismiss = { reasons.append($0) }
        handle.runAction()
        handle.runAction()
        #expect(actions == 1 && reasons == [.action])
    }

    @Test func newerToastsStackBelowAndTheRestMoveUp() {
        let host = CmuxToastHeadlessHost()
        let center = CmuxToastCenter(clock: ManualClock(), host: host)
        let window = Self.window()
        let first = center.show(Self.undo("a"), in: window)
        center.show(Self.undo("b"), in: window)
        center.show(CmuxToast(id: "c", message: "Saved"), in: window)
        #expect(host.slots.map(\.id) == ["c", "b", "a"], "slot 0 (bottom) is the newest")
        var reasons: [CmuxToastDismissReason] = []
        first.onDismiss = { reasons.append($0) }
        center.show(CmuxToast(id: "d", message: "Moved"), in: window)
        #expect(reasons == [.replaced])
        #expect(host.slots.map(\.id) == ["d", "c", "b"])
    }

    @Test func undoKeyRunsTheNewestUndoToast() {
        let center = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        let window = Self.window()
        var ran: [String] = []
        center.show(Self.undo("a"), in: window).onAction = { ran.append("a") }
        center.show(CmuxToast(id: "saved", message: "Saved"), in: window)
        center.show(Self.undo("b"), in: window).onAction = { ran.append("b") }
        #expect(center.takesUndoKey(in: window))
        #expect(center.runUndo(in: window))
        #expect(ran == ["b"])
        #expect(center.runUndo(in: window))
        #expect(ran == ["b", "a"])
        #expect(!center.takesUndoKey(in: window), "no undo toast left")
    }

    /// The coordinator's condition: a focused text field with something to
    /// undo keeps Cmd-Z; the toast's undo stays on its button.
    @Test func aFocusedTextFieldWithUndoKeepsCommandZ() throws {
        let window = Self.window()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let delegate = UndoDelegate(undo)
        window.delegate = delegate
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        text.allowsUndo = true
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.string = "hello"
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: text) { $0.string = "" }
        undo.endUndoGrouping()

        let center = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        var ran = false
        center.show(Self.undo("tab"), in: window).onAction = { ran = true }
        #expect(CmuxToastCenter.responderCanUndo(window.firstResponder))
        #expect(!center.takesUndoKey(in: window), "the text field keeps Cmd-Z")
        window.firstResponder?.undoManager?.undo()
        #expect(text.string.isEmpty, "Cmd-Z undid the text")
        #expect(!ran)
        #expect(center.takesUndoKey(in: window), "nothing left to undo in the field: the toast takes Cmd-Z")
        withExtendedLifetime(delegate) {}
    }

    @Test func aClosedWindowEndsItsToasts() {
        let host = CmuxToastHeadlessHost()
        let center = CmuxToastCenter(clock: ManualClock(), host: host)
        var reasons: [CmuxToastDismissReason] = []
        center.show(Self.undo("a"), in: Self.window()).onDismiss = { reasons.append($0) }
        host.closeWindow()
        #expect(reasons == [.closed])
    }

    @Test func theToastViewNamesItsMessageForVoiceOver() {
        let view = CmuxToastView(toast: Self.undo("tab"))
        #expect(view.accessibilityLabel() == "Hid tab")
        #expect(view.actionButton?.accessibilityLabel() == CmuxToastStrings.undo)
        #expect(view.closeButton.accessibilityLabel() == CmuxToastStrings.dismiss)
    }
}

@MainActor
final class UndoDelegate: NSObject, NSWindowDelegate {
    let undo: UndoManager
    init(_ undo: UndoManager) { self.undo = undo }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
}
