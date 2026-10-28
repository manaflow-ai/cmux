import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Leo (launch-speed-first): "the first frame is never blank". A terminal pane is held clear for
/// launch until its terminal's first live frame: about 150 ms of empty glass on a capture mini with
/// the daemon running (first window frame 3119 ms, first terminal frame 3266 ms), seconds when the
/// daemon starts cold. A terminal that showed at quit shows that frame from the launch's first
/// frame, until its live content draws.
@MainActor @Suite(.serialized) struct TerminalLaunchFrameTests {
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

        /// `rig`: the deadline scheduler the session's frame hold uses (its limits fire only when the test fires them).
        init(reveal: LaunchReveal, rig: MainDeadlineRig? = nil) {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            session = TerminalSession(io: io, mainWork: rig?.work ?? MainWorkScheduler(budget: MainFrameBudget()), deadlines: rig?.deadlines)
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

    /// Lawrence 2026-10-27 (restore targets): after a relaunch with 60 workspaces, three visible terminals showed an empty
    /// pane with a cursor box and "Restoring…". The pane showed its last frame from the first launch frame, but the hold
    /// gave up after 3 s (`contentLimit`) while the attach still waited for a busy daemon, so the empty surface showed
    /// until the attach came back (n=600 cold, optimized build: last frame at 1.0 s, pane empty from 4.0 s to 9.9 s).
    /// Chrome keeps a tab's last content up until the new content paints, however long that takes: the last frame
    /// stays until the terminal's first content is drawn.
    @Test func aLastFrameStaysUntilTheTerminalsContentDrawsHoweverLongTheAttachTakes() async throws {
        let rig = MainDeadlineRig()
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal, rig: rig)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.held != nil)
        // The attach answers late (a daemon that restores 600 workspaces): every deadline the session armed comes due.
        rig.advance(by: .seconds(30))
        for _ in 0..<16 where rig.hasArmedWake { rig.fireAndRun() }
        #expect(pane.held != nil, "the pane showed its empty terminal (a cursor box) while the attach was still pending")
        #expect(pane.session.frameHold.isHolding)
    }

    /// A frame of `size` at `scale`, filled with one opaque color (so a saved copy can be told from an empty surface).
    static func solid(_ size: NSSize, scale: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage {
        let image = frame(size, scale: scale)
        guard let rep = image.representations.first as? NSBitmapImageRep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    /// The color at the center of `image` (sRGB, 0...1).
    static func centerColor(_ image: NSImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = cg.cropping(to: CGRect(x: cg.width / 2, y: cg.height / 2, width: 1, height: 1)) else { return nil }
        let color = NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
        return color.map { ($0.redComponent, $0.greenComponent, $0.blueComponent) }
    }

    /// Review of cp/restore-frame-hold: the quit saves each terminal's frame for the next launch from its surface.
    /// A terminal still held over its slow attach showed its last frame, but the quit saved the empty surface under
    /// it: the next launch then showed an empty pane with a cursor box as the terminal's "last frame". The quit saves
    /// what the pane shows.
    @Test func aQuitDuringASlowAttachSavesTheHeldFrameNotTheEmptySurface() async throws {
        let rig = MainDeadlineRig()
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal, rig: rig)
        defer { pane.close() }
        pane.window.orderFrontRegardless()
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let scale = pane.window.backingScaleFactor
        let directory = try await Self.saved(["tab-1": Self.solid(pane.session.surfaceView.bounds.size, scale: scale, red: 1, green: 0, blue: 0)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        try #require(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        // The attach has not answered: the quit takes the frames now.
        let saved = await frames.frames(of: ["tab-1": pane.session])
        let image = try #require(saved["tab-1"], "the quit saved no frame for a terminal that showed its last frame")
        let center = try #require(Self.centerColor(image))
        #expect(center.red > 0.8 && center.green < 0.2 && center.blue < 0.2,
                "the quit saved \(center), not the frame the pane showed (red): the empty surface under the hold")
    }

    /// The hold ends once the terminal's content is queued and its `limit` passes (or the fresh surface draws it).
    @Test func aLastFrameEndsOnceTheTerminalsContentCame() async throws {
        let rig = MainDeadlineRig()
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal, rig: rig)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        try #require(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        pane.io.send(.replay(Data("restored\r\n".utf8)))
        for _ in 0..<300 where !pane.session.surfaceHasContent {
            rig.frame()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(pane.session.surfaceHasContent, "the replay never reached the session")
        for _ in 0..<300 where pane.session.frameHold.isHolding {
            if rig.hasArmedWake { rig.fireAndRun() } else { rig.frame() }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!pane.session.frameHold.isHolding, "the last frame stayed over the terminal's content")
        #expect(pane.held == nil)
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

    /// After a run that ended with no quit (`kill -9`), the saved frames are an earlier quit's screens.
    /// Shown, they drew an older screen that the daemon's live one then replaced; discarded, the terminal stays held
    /// clear until its live content draws, as with no saved frame.
    @Test func aDiscardedReadShowsNoFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        frames.discardLaunchRead()
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.held == nil, "an earlier quit's frame covers the terminal")
        #expect(pane.content.alphaValue == 0, "the pane waits for its first live frame, as with no saved frame")
        #expect(frames.launchFrameCount == 0)
        #expect(frames.prefetch(on: Self.work) == nil, "no read starts again")
    }

    /// Unlike the settle's drop, a discard while the read runs gives no frame to the panes that asked before it ended.
    @Test func aReadDiscardedWhileItRunsGivesTheWaitingPanesNoFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        let read = try #require(frames.prefetch(on: Self.work), "the launch read did not start")
        #expect(await probe.waitForStart(), "the read never started")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        frames.discardLaunchRead()
        probe.release()
        await read.value
        #expect(pane.held == nil, "the pane that asked before the read ended got an earlier quit's frame")
        #expect(pane.content.alphaValue == 0)
        #expect(frames.launchFrameCount == 0)
    }

    /// The decoded frames no pane took went 30 s after launch; they go once the launch settled.
    @Test func theLaunchReadHoldsNoFrameOnceTheLaunchSettled() async throws {
        let directory = try await Self.saved(["tab-1": Self.frame(Self.size, scale: 2), "tab-2": Self.frame(Self.size, scale: 2)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(frames.launchFrameCount == 2)
        frames.dropLaunchRead()
        #expect(frames.launchFrameCount == 0, "no decoded frame stays once the launch settled")
        #expect(frames.memoryUsage == .empty)
        #expect(frames.prefetch(on: Self.work) == nil, "no read starts again")
    }

    /// A launch that settles while the read runs: the panes that asked before it ended still get their frames,
    /// then the read holds none.
    @Test func aReadStillRunningAtTheSettleShowsTheWaitingPanesThenHoldsNoFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor),
                                              "tab-2": Self.frame(Self.size, scale: 2)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        let read = try #require(frames.prefetch(on: Self.work), "the launch read did not start")
        #expect(await probe.waitForStart(), "the read never started")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        frames.dropLaunchRead()
        probe.release()
        probe.release()  // one per saved file
        await read.value
        #expect(pane.held != nil, "the pane that asked before the read ended did not get its frame")
        #expect(frames.launchFrameCount == 0, "the frames no pane took stayed after the settle")
    }

    /// A launch that settles after the read's lane ended but before the main actor handed its frames to the panes
    /// that asked: those panes still get their frames, then the read holds none.
    @Test func aSettleBetweenTheLaneEndAndTheHandoffStillShowsTheWaitingPanes() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor),
                                              "tab-2": Self.frame(Self.size, scale: 2)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        // The prefetch task's handoff waits here until the settle below, as it does behind a busy main thread.
        let (handoff, openHandoff) = AsyncStream.makeStream(of: Void.self)
        frames.beforeHandoff = { for await _ in handoff { return } }
        defer { openHandoff.finish() }
        let read = try #require(frames.prefetch(on: Self.work), "the launch read did not start")
        let laneEnd = try #require(frames.launchReadLaneEnd)
        #expect(await probe.waitForStart(), "the read never started")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        probe.release()
        probe.release()  // one per saved file
        // The main actor suspends here, but the prefetch task's handoff waits for the settle below.
        await laneEnd()
        frames.dropLaunchRead()
        #expect(pane.held != nil, "the pane that asked before the read ended did not get its frame")
        #expect(frames.launchFrameCount == 0, "the frames no pane took stayed after the settle")
        openHandoff.yield()
        await read.value
        #expect(pane.held != nil)
    }

    /// The launch read reports its decoded bytes, and the critical limit drops it at once.
    @Test func theLaunchReadReportsItsBytesAndGoesAtCritical() async throws {
        let directory = try await Self.saved(["tab-1": Self.frame(Self.size, scale: 2)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        let usage = try #require(frames.memoryUsage)
        #expect(usage.entries == 1)
        #expect(usage.footprintBytes >= Int(Self.size.width * 2) * Int(Self.size.height * 2) * 3, "the decoded bitmap's bytes")
        #expect(TerminalLaunchFrames.memoryTraits.retention == .lossy)
        #expect(frames.releaseMemory(within: MemoryReleaseSlice(limit: MemoryLimit(percent: 50)) { false }) == .done)
        #expect(frames.launchFrameCount == 1, "only critical pressure drops the launch read")
        #expect(frames.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false }) == .done)
        #expect(frames.launchFrameCount == 0)
    }
}
