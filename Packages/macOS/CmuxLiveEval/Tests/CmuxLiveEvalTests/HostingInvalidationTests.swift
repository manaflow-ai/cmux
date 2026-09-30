import AppKit
import CmuxSwiftRender
import SwiftUI
import Testing
@testable import CmuxLiveEval

/// End-to-end invalidation through real SwiftUI: hosts ``InterpretedView``
/// (whose node rendering is AnyView-erased) in an offscreen NSHostingView,
/// mutates one box, and asserts SwiftUI re-ran only the stub whose statement
/// read that box. This is the GUI-free equivalent of watching
/// `Self._printChanges` in the demo app.
@MainActor
@Suite(.serialized) struct HostingInvalidationTests {
    /// Pumps the main run loop until `condition` or a bounded deadline
    /// (deterministic test scaffolding, not runtime synchronization).
    private func pump(until condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func host(
        _ source: String
    ) -> (engine: LiveEvalEngine, store: LiveStateStore, recorder: EvalRecorder, window: NSWindow) {
        let engine = LiveEvalEngine(program: LiveProgram.parse(source))
        let recorder = EvalRecorder()
        engine.onEvaluate = { recorder.append($0) }
        let store = engine.makeStore()
        let hosting = NSHostingView(rootView: InterpretedView(engine: engine, store: store))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (engine, store, recorder, window)
    }

    @Test func countMutationReEvaluatesOnlyCounterTextStub() {
        let (_, store, recorder, window) = host(LiveEvalFixtures.source)
        defer { window.orderOut(nil) }
        pump { !recorder.labels.isEmpty }
        #expect(recorder.labels.contains("root"), "initial render must evaluate the tree")

        recorder.clear()
        store.box("count")?.value = .int(41)
        pump { !recorder.labels.isEmpty }
        #expect(recorder.labels == [#"Text("Count: \(count)")"#],
                "only the stub that read `count` may re-evaluate, got \(recorder.labels)")
    }

    @Test func textMutationReEvaluatesOnlyTextReadingStubs() {
        let (_, store, recorder, window) = host(LiveEvalFixtures.source)
        defer { window.orderOut(nil) }
        pump { !recorder.labels.isEmpty }

        recorder.clear()
        store.box("text")?.value = .string("typed externally")
        pump { recorder.labels.contains(#"Text("Echo: \(text)")"#) }
        // Two stubs involve `text`: the echo Text (reads it during eval) and
        // the TextField stub (its binding getter runs under that stub's
        // update scope; compiled SwiftUI re-runs the binding-owning body the
        // same way). Counter, rows, and buttons must stay quiet.
        let allowed = Set([#"Text("Echo: \(text)")"#, #"TextField("Type here", text: $text)"#])
        #expect(recorder.labels.contains(#"Text("Echo: \(text)")"#))
        #expect(Set(recorder.labels).isSubset(of: allowed),
                "only text-reading stubs may re-evaluate, got \(recorder.labels)")
    }

    @Test func typedNSEventsRoundTripThroughRealTextField() {
        let (_, store, recorder, window) = host(LiveEvalFixtures.source)
        defer { window.orderOut(nil) }
        pump { !recorder.labels.isEmpty }

        guard let field = Self.firstEditableTextField(in: window.contentView) else {
            Issue.record("no editable NSTextField found under NSHostingView; SwiftUI TextField backing changed")
            return
        }
        #expect(window.makeFirstResponder(field), "TextField must accept first responder (focus)")
        recorder.clear()
        for character in "hey" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: String(character),
                    charactersIgnoringModifiers: String(character),
                    isARepeat: false,
                    keyCode: 0
                )
                if let event { window.sendEvent(event) }
            }
        }
        pump { store.box("text")?.value == .string("hey") }
        #expect(store.box("text")?.value == .string("hey"),
                "typed NSEvents must round-trip through the interpreted binding into the box")
        pump { recorder.labels.contains(#"Text("Echo: \(text)")"#) }
        #expect(recorder.labels.contains(#"Text("Echo: \(text)")"#),
                "the echo stub must re-evaluate from typing, got \(recorder.labels)")
    }

    private static func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = firstEditableTextField(in: subview) { return found }
        }
        return nil
    }
}
