import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// Leo (launch-speed-first): "the first frame is never blank". A terminal pane is held clear for
/// launch until its terminal's first live frame: about 150 ms of empty glass on a capture mini with
/// the daemon running (first window frame 3119 ms, first terminal frame 3266 ms), seconds when the
/// daemon starts cold. A terminal that showed at quit shows that frame from the launch's first
/// frame, until its live content draws.
@MainActor @Suite(.serialized) struct TerminalLaunchFrameTests {
    static let size = NSSize(width: 480, height: 240)

    /// A frame of `size` at 2x, as a quit saves it.
    static func frame(_ size: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
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
        await TerminalLaunchFrames(directory: directory).save(frames)
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
        let directory = try await Self.saved(["tab-1": Self.frame(Self.size)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        try #require(pane.session.surfaceView.surface != nil, "libghostty created no surface")
        let frames = TerminalLaunchFrames(directory: directory)
        #expect(frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 1, "the pane shows its terminal's last frame at once")
        #expect(pane.content.layer?.animation(forKey: "opacity") == nil, "with no fade: it is the frame the pane showed")
        #expect(pane.held?.frame.size == pane.session.surfaceView.frame.size, "the last frame covers the terminal")
        #expect(!reveal.isReady(.pane), "panes with no last frame still wait for their first live frame")
        #expect(!frames.show("tab-1", on: pane.session, in: pane.content, reveal: reveal), "a frame is shown once per launch")
    }

    @Test func aFrameOfAnotherSizeIsNotShown() async throws {
        let directory = try await Self.saved(["tab-1": Self.frame(NSSize(width: 640, height: 240))])
        defer { try? FileManager.default.removeItem(at: directory) }
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane = Pane(reveal: reveal)
        defer { pane.close() }
        #expect(!TerminalLaunchFrames(directory: directory).show("tab-1", on: pane.session, in: pane.content, reveal: reveal))
        #expect(pane.content.alphaValue == 0, "the pane waits for its first live frame, as before")
        #expect(pane.held == nil)
    }
}
