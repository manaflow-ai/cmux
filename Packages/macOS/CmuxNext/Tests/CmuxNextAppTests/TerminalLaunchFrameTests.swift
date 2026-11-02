import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing
import os

/// Leo (launch-speed-first): "the first frame is never blank". A terminal pane is held clear for
/// launch until its terminal's first live frame: about 150 ms of empty glass on a capture mini with
/// the daemon running (first window frame 3119 ms, first terminal frame 3266 ms), seconds when the
/// daemon starts cold. A terminal that showed at quit shows that frame from the launch's first
/// frame, until its live content draws.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalLaunchFrameTests {
    static let size = NSSize(width: 480, height: 240)
    static let work = BackgroundWork(label: "test.terminal-launch-frames")

    /// The frames of `directory` as the next launch reads them (before its first pane asks).
    static func launch(_ directory: URL) async -> TerminalLaunchFrames {
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.prefetch(on: work)?.value
        return frames
    }

    /// A frame of `size` at `scale`, as a quit saves it.
    static func frame(_ size: NSSize, scale: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        let image = NSImage(size: size)
        if let rep { image.addRepresentation(rep) }
        return image
    }

    /// The tag state's directory, saved at the last quit with `frames`.
    static func saved(_ frames: [String: NSImage]) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "terminal-launch-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await TerminalLaunchFrames(directory: directory).save(images: frames)
        return directory
    }

    /// A pane's content at launch, held for the pane region, with a terminal whose session has
    /// not attached yet.
    @MainActor struct Pane {
        let window: NSWindow
        let content: NSView
        let io = ScriptedTerminalIO()
        let session: TerminalSession

        init(reveal: LaunchReveal) {
            _ = NSApplication.shared
            session = TerminalSession(io: io)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: TerminalLaunchFrameTests.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = NSView(frame: NSRect(origin: .zero, size: TerminalLaunchFrameTests.size))
            window.contentView = content
            reveal.hold(content, until: .pane)
            session.view.frame = content.bounds
            content.addSubview(session.view)
            session.view.layoutSubtreeIfNeeded()
        }

        /// The frame drawn over the terminal's surface, if any.
        var held: NSView? {
            session.view.subviews.last { $0 !== session.surfaceView && ($0.layer?.contents).map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID } == true }
        }

        func close() {
            io.finish()
            window.close()
        }
    }

    @Test func aTerminalShownAtQuitShowsItsLastFrameFromTheFirstLaunchFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        // Saved at quit at the terminal's size in this pane (the pane less its scroller, if any).
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 1, "the pane shows its terminal's last frame at once")
        #expect(pane.content.layer?.animation(forKey: "opacity") == nil, "with no fade: it is the frame the pane showed")
        #expect(pane.held?.frame.size == pane.session.surfaceView.frame.size, "the last frame covers the terminal")
        #expect(!reveal.isReady(.pane), "panes with no last frame still wait for their first live frame")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal), "a frame is shown once per launch")
    }

    /// Slice (c) of the main-thread sweep: the frame (up to 16 MB) was read and decoded on the main thread as
    /// the pane showed its terminal. The launch now reads every frame off the main thread from its start; a pane
    /// shown before that read ends never waits: it stays held clear, as with no frame, and gets its frame when
    /// the read ends (it still had nothing live).
    @Test func aPaneShownBeforeTheReadEndsStaysClearThenGetsItsFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let marks = LaunchMarks()
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        let prefetch = frames.prefetch(on: Self.work, mark: { marks.record($0) })
        let read = try #require(prefetch, "the launch read did not start")
        let started = await probe.waitForStart()
        #expect(started, "the read never started")
        // The read is held on its lane: a show that waited for it would never return.
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 0, "the pane showed before its frame came: as with no frame, it stays held")
        #expect(pane.held == nil)
        probe.release()
        await read.value
        #expect(marks.names == ["terminal.launch_frame_missed", "terminal.launch_frames_read", "terminal.launch_frame_shown"])
        #expect(pane.content.alphaValue == 1, "the pane did not show its terminal's last frame once it was read")
        #expect(pane.held != nil, "the last frame does not cover the terminal")
        #expect(probe.reads == [false], "the saved frame was read on the main thread")
    }

    @Test func aFrameSavedOnAScreenOfAnotherScaleIsNotShown() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        let scale: CGFloat = pane.window.backingScaleFactor == 2 ? 1 : 2
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: scale)])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await !Self.launch(directory).show("tab-1", on: pane.session, in: pane.content, reveal: reveal),
                "it would draw at the window's scale, twice or half its size")
        #expect(pane.content.alphaValue == 0)
    }

    @Test func aFrameOfAnotherSizeIsNotShown() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        // Saved in a wider window.
        let surface = pane.session.surfaceView.bounds.size
        let directory = try await Self.saved(["tab-1": Self.frame(NSSize(width: surface.width + 160, height: surface.height), scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await !Self.launch(directory).show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 0, "the pane waits for its first live frame, as before")
        #expect(pane.held == nil)
    }

    /// A pane's content held for launch whose terminal has no surface yet (the scheduler keeps it for a later frame).
    @MainActor struct WaitingPane {
        let window: NSWindow
        let content: NSView

        init(reveal: LaunchReveal) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: TerminalLaunchFrameTests.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = NSView(frame: NSRect(origin: .zero, size: TerminalLaunchFrameTests.size))
            window.contentView = content
            reveal.hold(content, until: .pane)
        }

        /// The surface's size in this pane (`TerminalHostView.surfaceWidth`).
        var surfaceSize: NSSize { NSSize(width: TerminalHostView.surfaceWidth(hostWidth: content.bounds.width), height: content.bounds.height) }
    }

    /// REOPEN-F1: a pane waiting for its surface shows its last frame at once, unheld, and the surface takes it over.
    @Test func aPaneWaitingForItsSurfaceShowsItsFrameAtOnceAndTheSurfaceTakesItOver() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = WaitingPane(reveal: reveal)
        defer { waiting.window.close() }
        let directory = try await Self.saved(["tab-1": Self.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(frames.showAhead("tab-1", in: waiting.content, reveal: reveal))
        #expect(waiting.content.alphaValue == 1, "the pane stays held clear: the window's first frame shows it empty")
        #expect(frames.showsAhead(in: waiting.content))
        // Its surface comes on a later frame.
        let io = ScriptedTerminalIO()
        defer { io.finish() }
        let session = TerminalSession(io: io)
        session.view.frame = waiting.content.bounds
        waiting.content.addSubview(session.view)
        #expect(frames.show("tab-1", on: session, in: waiting.content, reveal: reveal), "the surface did not take the frame over")
        #expect(!frames.showsAhead(in: waiting.content), "two frames: the one shown ahead stayed over the surface")
        #expect(waiting.content.alphaValue == 1)
    }

    /// The reopen number is the LAST terminal of the first window frame to show its frame, never the first; a terminal
    /// that never shows one leaves it unset.
    @Test func theLaunchNumberIsTheLastPaneAndOnlyOnceEveryPaneShowed() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let left = WaitingPane(reveal: reveal), right = WaitingPane(reveal: reveal), bare = WaitingPane(reveal: reveal)
        defer { for pane in [left, right, bare] { pane.window.close() } }
        let image = Self.frame(left.surfaceSize, scale: left.window.backingScaleFactor)
        let directory = try await Self.saved(["tab-l": image, "tab-r": image])
        defer { try? FileManager.default.removeItem(at: directory) }
        let drawn = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.prefetch(on: Self.work, markAt: { name, date in drawn.withLock { $0[name] = date } })?.value
        #expect(frames.showAhead("tab-l", in: left.content, reveal: reveal))
        #expect(frames.showAhead("tab-r", in: right.content, reveal: reveal))
        frames.closeLaunch()
        let last = try #require(frames.lastLaunchPaneShown)
        #expect(last == frames.launchPanes.values.compactMap(\.shown).max(), "the launch number is not the last pane")
        #expect(drawn.withLock { $0[TerminalLaunchFrames.visibleTerminalsDrawn] } == last)
        // A launch with a terminal that has no saved frame is not drawn by the frames.
        let other = try await Self.saved(["tab-l": image])
        defer { try? FileManager.default.removeItem(at: other) }
        let partial = TerminalLaunchFrames(directory: other)
        await partial.prefetch(on: Self.work)?.value
        #expect(partial.showAhead("tab-l", in: left.content, reveal: reveal))
        #expect(!partial.showAhead("tab-none", in: bare.content, reveal: reveal))
        partial.closeLaunch()
        #expect(partial.lastLaunchPaneShown == nil, "a pane with no frame counted as drawn")
        #expect(partial.launchPanes["tab-none"]?.missed == "no_frame")
    }

    /// Review P1: a pane that asked ahead while the read ran, then showed something else, never gets that frame over
    /// its new content when the read ends.
    @Test func anAskAheadThatTheSelectionReplacedShowsNoFrameWhenTheReadEnds() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = WaitingPane(reveal: reveal)
        defer { waiting.window.close() }
        let directory = try await Self.saved(["tab-1": Self.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        let read = try #require(frames.prefetch(on: Self.work), "the launch read did not start")
        #expect(await probe.waitForStart(), "the read never started")
        #expect(!frames.showAhead("tab-1", in: waiting.content, reveal: reveal))
        // The pane shows a page now.
        frames.withdrawAhead(in: waiting.content)
        probe.release()
        await read.value
        #expect(!frames.showsAhead(in: waiting.content), "the old tab's frame went over the content the pane shows now")
    }
}
