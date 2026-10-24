import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextLaunch
@testable import CmuxNextTerminal
import Dispatch
import ImageIO
import Testing

/// Leo (launch-speed-first): "the first frame is never blank". A terminal pane is held clear for
/// launch until its terminal's first live frame: about 150 ms of empty glass on a capture mini with
/// the daemon running (first window frame 3119 ms, first terminal frame 3266 ms), seconds when the
/// daemon starts cold. A terminal that showed at quit shows that frame from the launch's first
/// frame, until its live content draws.
@MainActor @Suite(.serialized) struct TerminalLaunchFrameTests {
    static let size = NSSize(width: 480, height: 240)

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
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.decoded()  // read and decoded off the main thread (SavedFrameDirectory), as from `main`
        #expect(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 1, "the pane shows its terminal's last frame at once")
        #expect(pane.content.layer?.animation(forKey: "opacity") == nil, "with no fade: it is the frame the pane showed")
        #expect(pane.held?.frame.size == pane.session.surfaceView.frame.size, "the last frame covers the terminal")
        #expect(!reveal.isReady(.pane), "panes with no last frame still wait for their first live frame")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal), "a frame is shown once per launch")
    }

    @Test func aFrameSavedOnAScreenOfAnotherScaleIsNotShown() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        let scale: CGFloat = pane.window.backingScaleFactor == 2 ? 1 : 2
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: scale)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.decoded()
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal),
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
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.decoded()
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 0, "the pane waits for its first live frame, as before")
        #expect(pane.held == nil)
    }

    /// #17587: the pane build never waits for a frame the launch has not decoded yet (the decode
    /// below is held, so a take that waited would never return); the frame shows over the terminal
    /// as soon as it is decoded, while the terminal has drawn nothing of its own.
    @Test func aFrameDecodedAfterThePaneWasBuiltShowsWhenItIs() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let directory = try await Self.saved(["tab-1": Self.frame(pane.session.surfaceView.bounds.size, scale: pane.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        // A test gate on the reader's own queue, not a lock on state: the decode waits until the pane was built.
        let gate = DispatchSemaphore(value: 0)
        let frames = TerminalLaunchFrames(frames: SavedFrameDirectory(url: directory, name: "test_frames") { file, scale in
            gate.wait()
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return SavedFrame(image: image, scale: scale)
        })
        let (shown, didShow) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames.onLateFrameShown = { didShow.yield() }
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal), "not decoded yet: nothing now, and no wait")
        #expect(pane.content.alphaValue == 0)
        gate.signal()
        for await _ in shown { break }
        #expect(pane.content.alphaValue == 1, "the pane shows its terminal's last frame once it is decoded")
        #expect(pane.held?.frame.size == pane.session.surfaceView.frame.size)
    }

    /// #17587 review: the launch's frames are the store its services hand to the pane builds and the
    /// quit (`LaunchFiles.terminalFrames`), not a process-wide registry keyed by the state URL. Before,
    /// a second launch graph on the same state directory got the first one's store back, so a frame
    /// one had handed out was gone for the other, and each one's `onLateFrameShown` replaced the
    /// other's.
    @Test func eachLaunchsFramesAreItsOwnStore() async throws {
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        let other = Pane(reveal: reveal)
        defer { pane.close(); other.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let state = FileManager.default.temporaryDirectory.appending(path: "launch-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let size = pane.session.surfaceView.bounds.size
        await TerminalLaunchFrames(directory: TerminalLaunchFrames.directory(beside: state))
            .save(images: ["tab-1": Self.frame(size, scale: pane.window.backingScaleFactor)])
        let home = ChiefHome(root: state.appending(path: "chief"), isolated: false, buildID: ChiefHome.nightlyBundleID)
        let first = LaunchFiles(state: state, chiefHome: home)
        let second = LaunchFiles(state: state, chiefHome: home)
        await first.terminalFrames.decoded()
        await second.terminalFrames.decoded()
        #expect(first.terminalFrames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(second.terminalFrames.show("tab-1", on: other.session, in: other.content, reveal: reveal),
                "another launch graph's store handed out this one's frame")
    }
}
