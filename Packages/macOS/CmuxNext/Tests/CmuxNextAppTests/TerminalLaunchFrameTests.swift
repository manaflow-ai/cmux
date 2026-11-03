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

    /// Lawrence 2026-10-27 (restore): after a relaunch with 60 workspaces, three visible terminals showed an empty pane
    /// with a cursor box and "Restoring…". The pane showed its last frame from the first launch frame, but the hold gave
    /// up after 3 s while the attach still waited for a busy daemon, so the empty surface showed until the attach came
    /// back. Chrome keeps a tab's last content up until the new content paints, however long that takes: the last frame
    /// stays until the terminal's first content is drawn.
    @Test func aLastFrameStaysUntilTheTerminalsContentDrawsHoweverLongTheAttachTakes() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.held != nil)
        // The attach answers late (a daemon that restores hundreds of workspaces): nothing but the terminal's
        // content may end the hold, so no timer runs for it before that content comes.
        #expect(!pane.session.frameHold.hasDeadline,
                "a timer ends the last frame before the attach answers: the pane then shows its empty terminal (a cursor box)")
        #expect(pane.held != nil)
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

    /// The quit saves each visible terminal's frame for the next launch from its surface. A terminal still held over its
    /// slow attach showed its last frame, but the quit saved the empty surface under it (or nothing, before its first
    /// draw): the next launch then showed an empty pane with a cursor box as the terminal's last frame. The quit saves
    /// what the pane shows.
    @Test func aQuitDuringASlowAttachSavesTheHeldFrameNotTheEmptySurface() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        pane.window.orderFrontRegardless()
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let scale = pane.window.backingScaleFactor
        let directory = try await Self.saved(["tab-1": Self.solid(pane.session.surfaceView.bounds.size, scale: scale, red: 1, green: 0, blue: 0)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        try #require(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        // The attach has not answered: the quit saves the frames now (into its own directory, so the launch's red file
        // can never pass for a saved one).
        let quit = FileManager.default.temporaryDirectory.appending(path: "terminal-launch-frames-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: quit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: quit) }
        await TerminalLaunchFrames(directory: quit).save(["tab-1": pane.session])
        let file = try #require(try FileManager.default.contentsOfDirectory(at: quit, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("tab-1") }, "the quit saved no frame for a terminal that showed its last frame")
        let image = try #require(NSImage(contentsOf: file))
        let center = try #require(Self.centerColor(image))
        #expect(center.red > 0.8 && center.green < 0.2 && center.blue < 0.2,
                "the quit saved \(center), not the frame the pane showed (red): the empty surface under the hold")
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

    /// Issue #32493: a frame refused for its size reported `no_frame` once the pane asked again (the frame was taken by
    /// the first ask), so `debug.timings` hid the real cause of an empty pane at reopen. The first reason stays.
    @Test func aFrameRefusedForItsSizeReportsSizeWhenThePaneAsksAgain() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        let surface = pane.session.surfaceView.bounds.size
        let directory = try await Self.saved(["tab-1": Self.frame(NSSize(width: surface.width + 160, height: surface.height), scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(frames.launchPanes["tab-1"]?.missed == "size")
        // The pane asks again (its selection settles, or its surface comes after a show ahead).
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(frames.launchPanes["tab-1"]?.missed == "size",
                "the second ask replaced the reason: \(frames.launchPanes["tab-1"]?.missed ?? "nil") hides why the pane was empty")
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
        #expect(waiting.content.alphaValue == 1, "the pane stayed held clear: the window's first frame would show it empty")
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

    /// Issue #32274: under STRESS, 3 of 20 reopens had a visible pane that showed no saved frame (an empty pane until
    /// its live content). At the quit before, that pane still showed its frame ahead of its surface (the surface had not
    /// come, so it had no session), and the quit replaced the saved frames with the sessions' frames only: it removed
    /// the frame of a pane on screen. A pane still waiting for its surface at a quit keeps the frame it shows.
    @Test func aPaneStillWaitingForItsSurfaceAtQuitKeepsItsFrameForTheNextLaunch() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = WaitingPane(reveal: reveal), next = WaitingPane(reveal: reveal)
        defer { for pane in [waiting, next] { pane.window.close() } }
        waiting.window.orderFrontRegardless()
        let directory = try await Self.saved(["tab-1": Self.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = await Self.launch(directory)
        try #require(frames.showAhead("tab-1", in: waiting.content, reveal: reveal))
        // The app quits before the pane's surface comes: no session shows the pane yet.
        await frames.save([:])
        #expect(await Self.launch(directory).showAhead("tab-1", in: next.content, reveal: reveal),
                "the quit removed the frame of a pane on screen: the next launch shows that pane empty")
    }

    /// Review of #32372 (P3): a pane that asked ahead of its surface while the launch read still ran gets its frame
    /// when the read ends; a quit before then must not remove that frame either.
    @Test func aPaneThatAskedAheadBeforeTheReadEndedKeepsItsFrameAtQuit() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = WaitingPane(reveal: reveal), next = WaitingPane(reveal: reveal)
        defer { for pane in [waiting, next] { pane.window.close() } }
        waiting.window.orderFrontRegardless()
        let directory = try await Self.saved(["tab-1": Self.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let frames = TerminalLaunchFrames(directory: directory, reader: probe.reader)
        let read = try #require(frames.prefetch(on: Self.work), "the launch read did not start")
        #expect(await probe.waitForStart(), "the read never started")
        #expect(!frames.showAhead("tab-1", in: waiting.content, reveal: reveal), "it shows nothing before the read ends")
        // The app quits while the read still runs: no session shows the pane.
        await frames.save([:])
        probe.release()
        await read.value
        #expect(await Self.launch(directory).showAhead("tab-1", in: next.content, reveal: reveal),
                "the quit removed the frame of a pane waiting for the read: the next launch shows that pane empty")
    }

    /// Review of #32372 (P3): the launch read takes at most `maximumFiles` names, and it took them before it kept only
    /// saved frames. Atomic-write files left by kills mid-write (`<key>@1x.jpg.sb-<id>`) sort before a later key and
    /// took every slot: that terminal showed no frame.
    @Test func filesLeftByKilledWritesNeverCrowdOutASavedFrame() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = WaitingPane(reveal: reveal)
        defer { waiting.window.close() }
        let directory = try await Self.saved(["tab_z": Self.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<TerminalLaunchFrames.maximumFiles {
            try Data("partial".utf8).write(to: directory.appending(path: "tab_a\(index)@1x.jpg.sb-killed-\(index)"))
        }
        #expect(await Self.launch(directory).showAhead("tab_z", in: waiting.content, reveal: reveal),
                "files of killed writes took the read's slots: the saved frame was never read")
    }

    /// Review of #32372 (P3): a terminal on screen whose shown image gives no bitmap at quit keeps its saved frame.
    @Test func aShownTerminalWhoseImageGivesNoBitmapKeepsItsSavedFrame() async throws {
        let directory = try await Self.saved(["tab-1": Self.frame(Self.size, scale: 1)])
        defer { try? FileManager.default.removeItem(at: directory) }
        // An image with no representation gives no CGImage.
        await TerminalLaunchFrames(directory: directory).save(images: ["tab-1": NSImage(size: Self.size)])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(names.contains { TerminalLaunchFrames.owner(of: $0) == "tab-1" },
                "the quit removed the saved frame of a terminal on screen it had no new frame for")
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
