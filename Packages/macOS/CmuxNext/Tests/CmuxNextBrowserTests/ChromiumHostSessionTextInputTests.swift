#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// The page view's text input on the session's wire: the session asks the host
/// for its text input state, applies each push to the view, and sends the view's ops on the same
/// stream as its key and mouse frames, each after the frames written before it.
extension ChromiumHostSessionTests {
    /// A host frame the test compares: key and mouse frames by phase, ops by their op number.
    enum Wired: Equatable {
        case key(phase: Int32)
        case mouse(phase: Int32)
        case ime(op: Int32)
    }

    @Test(.timeLimit(.minutes(1))) func textInputOpsRideTheStreamInOrderWithInput() async throws {
        _ = NSApplication.shared
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            session.view.removeFromSuperview()
            window.close()
            session.close()
        }
        session.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(session.view)
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        // A text field with the caret at 3; the title after it says the push was applied.
        host.wire.send(ChromiumHostTextInputTests.stateFrame(caret: [30, 10, 1, 16], textOffset: 0, rects: [], text: "abc"))
        host.wire.send(ChromiumHostFrame(.title, payload: Array("pushed".utf8)))
        try await until("the push is applied") { session.title == "pushed" }
        #expect(session.view.textInput.state.type == .text)
        #expect(session.view.selectedRange() == NSRange(location: 7, length: 0))
        #expect(session.view.inputContext != nil)

        let view = session.view
        let keyUp = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "a",
                                                  charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                                                   timestamp: 2, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        view.keyUp(with: keyUp)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.mouseDown(with: down)
        view.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))

        var watched = false
        var wired: [Wired] = []
        var frames = host.wire.frames.makeAsyncIterator()
        while wired.count < 5, let frame = await frames.next() {
            switch frame.kind {
            case .textInputWatch: watched = frame.v[0] == 1
            case .key: wired.append(.key(phase: frame.v[0]))
            case .mouse: wired.append(.mouse(phase: frame.v[2]))
            case .ime: wired.append(.ime(op: frame.v[0]))
            default: break
            }
        }
        #expect(watched, "the session asks for the text input state")
        #expect(wired == [.key(phase: 1), .ime(op: 0), .ime(op: 2), .mouse(phase: 1), .ime(op: 1)])
        #expect((session.report["ime_first_rect_misses"] as? Int) == 0)
    }

    /// The host ends: its field went with it, so the composition ends and no input method stays.
    @Test(.timeLimit(.minutes(1))) func aHostThatEndsTakesTheFieldAway() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        defer { session.close() }
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 5, address: "https://a.example/")
        first.wire.send(ChromiumHostTextInputTests.stateFrame(caret: [30, 10, 1, 16], textOffset: 0, rects: [], text: "abc"))
        first.wire.send(ChromiumHostFrame(.title, payload: Array("pushed".utf8)))
        try await until("the push is applied") { session.title == "pushed" }
        session.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(session.view.hasMarkedText())
        launcher.end(first, ChromiumHostExit(signal: SIGKILL, status: nil))
        _ = try await nextLaunch(launcher)
        #expect(session.view.textInput.state.type == .noField)
        #expect(!session.view.hasMarkedText())
    }
}
#endif
