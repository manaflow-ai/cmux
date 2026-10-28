import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Audit B3: a terminal's held frame (`TerminalFrameHold`) covered the live terminal for up to 500 ms after its
/// content was queued and parsed, and up to 3 s before. Once the content is parsed the live surface is what the
/// person must see: the held frame stays at most two frames for the fresh surface to present, and a key or a click
/// in the terminal ends it before the input is handled, so the echo is never drawn under a picture.
@MainActor @Suite(.serialized) struct TerminalFrameHoldInputTests {
    /// A terminal pane in a window that is never ordered in (its renderer presents nothing new), whose frame hold
    /// runs on `rig`'s deadlines.
    @MainActor struct Pane {
        let window: NSWindow
        let content: NSView
        let io = ScriptedTerminalIO()
        let session: TerminalSession

        init(rig: MainDeadlineRig) {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            session = TerminalSession(io: io, mainWork: rig.work, deadlines: rig.deadlines)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: TerminalLaunchFrameTests.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = NSView(frame: NSRect(origin: .zero, size: TerminalLaunchFrameTests.size))
            window.contentView = content
            session.view.frame = content.bounds
            content.addSubview(session.view)
            session.view.layoutSubtreeIfNeeded()
        }

        func close() {
            io.finish()
            window.close()
        }
    }

    /// The pane shows its last frame from the last quit, then its terminal's content comes and is parsed: the hold
    /// now only waits for the fresh surface to present it.
    static func heldOverParsedContent(_ rig: MainDeadlineRig) async throws -> Pane {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(rig: rig)
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        reveal.hold(pane.content, until: .pane)
        let directory = try await TerminalLaunchFrameTests.saved(
            ["tab-1": TerminalLaunchFrameTests.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await TerminalLaunchFrameTests.launch(directory)
        try #require(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        pane.io.send(.replay(Data("restored\r\n".utf8)))
        for _ in 0..<300 where !pane.session.frameHold.drawsParsedContent {
            rig.frame()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(pane.session.surfaceHasContent, "the replay never reached the session")
        try #require(pane.session.frameHold.drawsParsedContent, "the replay was never parsed")
        try #require(pane.session.frameHold.isHolding, "precondition: the held frame waits for the fresh surface to present")
        return pane
    }

    @Test func onceTheContentIsParsedTheHeldFrameStaysAtMostTwoFrames() async throws {
        let rig = MainDeadlineRig()
        let pane = try await Self.heldOverParsedContent(rig)
        defer { pane.close() }
        rig.advance(by: .milliseconds(34))
        rig.fireAtNow()
        #expect(!pane.session.frameHold.isHolding, "the held frame still covered the live terminal two frames after its content was parsed")
    }

    @Test func aKeyInTheTerminalEndsTheHeldFrameBeforeItIsHandled() async throws {
        let rig = MainDeadlineRig()
        let pane = try await Self.heldOverParsedContent(rig)
        defer { pane.close() }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: pane.window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        pane.session.surfaceView.keyDown(with: key)
        #expect(!pane.session.frameHold.isHolding, "the key's echo was drawn under the held frame")
    }

    @Test func aClickInTheTerminalEndsTheHeldFrame() async throws {
        let rig = MainDeadlineRig()
        let pane = try await Self.heldOverParsedContent(rig)
        defer { pane.close() }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40), modifierFlags: [],
                                                    timestamp: 0, windowNumber: pane.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        pane.session.surfaceView.mouseDown(with: click)
        #expect(!pane.session.frameHold.isHolding, "a click landed on the terminal under the held frame")
    }

    @Test func beforeTheContentComesAKeyKeepsTheLastFrame() async throws {
        let rig = MainDeadlineRig()
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(rig: rig)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        reveal.hold(pane.content, until: .pane)
        let directory = try await TerminalLaunchFrameTests.saved(
            ["tab-1": TerminalLaunchFrameTests.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await TerminalLaunchFrameTests.launch(directory)
        try #require(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: pane.window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        pane.session.surfaceView.keyDown(with: key)
        #expect(pane.session.frameHold.isHolding, "a key before the terminal had content showed its empty surface")
    }
}
