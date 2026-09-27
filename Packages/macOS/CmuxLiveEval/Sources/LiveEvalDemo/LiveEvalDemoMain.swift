import AppKit
import CmuxLiveEval
import CmuxSwiftRender
import SwiftUI

// Throwaway spike demo binary (not shipped, strings deliberately unlocalized).
//
// Hosts InterpretedView in a real window. `--self-test` drives it without a
// human: focuses the TextField, delivers real NSEvent keystrokes through
// window.sendEvent (never system-wide), prints _printChanges/evaluation
// traces plus the round-tripped state, then terminates itself.
@main
@MainActor
struct LiveEvalDemoMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LiveEvalDemoDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class LiveEvalDemoDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var store: LiveStateStore?
    private var engine: LiveEvalEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = LiveEvalEngine(program: LiveProgram.parse(Self.demoSource))
        engine.tracesBodyChanges = true
        engine.onEvaluate = { label in print("[eval] \(label)") }
        let store = engine.makeStore()
        self.engine = engine
        self.store = store

        let hosting = NSHostingView(rootView: InterpretedView(engine: engine, store: store).padding(12))
        let selfTest = CommandLine.arguments.contains("--self-test")
        // Self-test runs offscreen so the demo never steals the user's focus.
        let origin = selfTest ? NSPoint(x: -4000, y: -4000) : NSPoint(x: 200, y: 200)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 320, height: 420)),
            styleMask: selfTest ? [.borderless] : [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiveEval Demo"
        window.contentView = hosting
        window.orderBack(nil)
        self.window = window

        if selfTest {
            Task { await runSelfTest() }
        }
    }

    private func runSelfTest() async {
        guard let window, let store else { return }
        // Bounded settle delay: throwaway demo scaffolding, not runtime code.
        try? await Task.sleep(for: .milliseconds(400))

        guard let field = Self.firstTextField(in: window.contentView) else {
            print("[self-test] FAIL: no NSTextField found in hosted SwiftUI tree")
            NSApp.terminate(nil)
            return
        }
        let focused = window.makeFirstResponder(field)
        print("[self-test] focus TextField: \(focused ? "ok" : "FAILED")")

        print("[self-test] typing 'hi!' via window.sendEvent NSEvents")
        for character in "hi!" {
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
        try? await Task.sleep(for: .milliseconds(400))

        let text = store.box("text")?.value.displayString ?? "<missing>"
        print("[self-test] state box 'text' after typing: \"\(text)\"")
        print("[self-test] round-trip \(text == "hi!" ? "PASS" : "FAIL")")

        print("[self-test] mutating 'count' box; watch which stubs re-evaluate")
        store.box("count")?.value = .int(41)
        try? await Task.sleep(for: .milliseconds(400))
        NSApp.terminate(nil)
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    static let demoSource = """
    @State var count = 0
    @State var text = ""
    @State var rows = [
        ["id": "a", "label": "Alpha", "isOn": false],
        ["id": "b", "label": "Beta", "isOn": true],
        ["id": "c", "label": "Gamma", "isOn": false],
    ]

    VStack(spacing: 8) {
        Button("Increment") {
            count += 1
        }
        Text("Count: \\(count)")
        Divider()
        TextField("Type here", text: $text)
        Text("Echo: \\(text)")
        Divider()
        ForEach($rows, id: \\.id) { $row in
            Toggle(row.label, isOn: $row.isOn)
        }
        Button("Shuffle") {
            rows.shuffle()
        }
        Spacer()
    }
    """
}
