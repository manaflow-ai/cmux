import CmuxNextCompat
@testable import CmuxNextTerminal
import IOSurface
import Testing

/// A paused surface's held frame (``TerminalHeldFrame``) and an evicted terminal's last frame read the
/// renderer's presented frame and hide, show and purge it through the renderer (``TerminalFrameSource``);
/// nothing writes a layer's contents.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct TerminalHeldFrameTests {
    /// A renderer that presents `presented` and records what main asks of it, with ghostty-next's
    /// presentation states (Metal.zig `setPresentation`): HIDDEN and PURGE stop presenting (PURGE also
    /// drops the frame), and only SHOWN presents again and queues a frame.
    final class Renderer: TerminalFrameSource {
        var presented: IOSurface?
        private(set) var presentations: [TerminalPresentation] = []
        /// Whether the renderer presents: false after HIDDEN or PURGE until the next SHOWN.
        private(set) var presenting = true
        /// A SHOWN after HIDDEN or PURGE queued a fresh frame.
        private(set) var queuedFrame = false

        init(presenting presented: IOSurface?) {
            self.presented = presented
        }

        var presentedFrame: IOSurface? { presented }

        func setPresentation(_ presentation: TerminalPresentation) {
            presentations.append(presentation)
            switch presentation {
            case .hidden:
                presenting = false
            case .purge:
                presenting = false
                presented = nil
            case .shown:
                if !presenting { queuedFrame = true }
                presenting = true
            }
        }
    }

    /// A 64 x 64 BGRA surface standing in for a presented drawable.
    private func drawable() throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
    }

    /// The surface's purgeable state as the kernel keeps it (kIOSurfacePurgeableKeepCurrent reads it).
    private func purgeableState(_ surface: IOSurface) -> UInt32 {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, 3, &old)
        return old
    }

    /// Memory pressure took the pages.
    private func purge(_ surface: IOSurface) {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, IOSurface.purgeableEmpty, &old)
    }

    @Test func aPauseHidesThePresentedFrameAndADrawShowsItNonVolatile() throws {
        let frame = try drawable()
        let renderer = Renderer(presenting: frame)
        var held = TerminalHeldFrame()

        held.hold(volatile: true, in: renderer)
        #expect(held.frame === frame)
        #expect(purgeableState(frame) == IOSurface.purgeableVolatile)
        #expect(renderer.presentations == [.hidden])

        held.hold(volatile: false, in: renderer)
        #expect(held.frame == nil)
        #expect(purgeableState(frame) == IOSurface.purgeableNonVolatile)
        #expect(renderer.presentations == [.hidden, .shown])
        #expect(renderer.presented === frame)
        #expect(renderer.presenting)
    }

    @Test func aFramePurgedWhileHiddenIsDroppedByTheRenderer() throws {
        let frame = try drawable()
        let renderer = Renderer(presenting: frame)
        var held = TerminalHeldFrame()

        held.hold(volatile: true, in: renderer)
        purge(frame)
        held.hold(volatile: false, in: renderer)
        #expect(renderer.presentations == [.hidden, .purge, .shown], "dropped before the show, never after it")
        #expect(renderer.presented == nil, "no reader sees the empty frame")
        #expect(renderer.presenting, "the shown pane presents again")
        #expect(renderer.queuedFrame, "the show queues a fresh frame for the purged one")
    }

    /// A frame in flight at the pause replaced the held one: the new one was never made volatile, so a
    /// draw leaves it as it is.
    @Test func aFramePresentedAfterThePauseIsLeftAsItIs() throws {
        let old = try drawable(), newer = try drawable()
        let renderer = Renderer(presenting: old)
        var held = TerminalHeldFrame()

        held.hold(volatile: true, in: renderer)
        renderer.presented = newer
        held.hold(volatile: false, in: renderer)
        #expect(renderer.presentations == [.hidden, .shown])
        #expect(renderer.presenting)
        #expect(purgeableState(newer) == IOSurface.purgeableNonVolatile)
        #expect(purgeableState(old) == IOSurface.purgeableVolatile)
    }

    @Test func aReadOfAHeldFrameReclaimsItForTheReadOnly() throws {
        let frame = try drawable()
        let renderer = Renderer(presenting: frame)
        var held = TerminalHeldFrame()
        held.hold(volatile: true, in: renderer)

        let begun = held.beginRead(from: renderer)  // mutating: #require's call form would make `held` a let
        let read = try #require(begun)
        #expect(read === frame)
        #expect(purgeableState(frame) == IOSurface.purgeableNonVolatile)
        held.endRead(read)
        #expect(purgeableState(frame) == IOSurface.purgeableVolatile)
        #expect(renderer.presentations == [.hidden], "a read changes nothing the renderer presents")
    }

    @Test func aReadOfAPurgedHeldFrameGetsNothingAndPurgesIt() throws {
        let frame = try drawable()
        let renderer = Renderer(presenting: frame)
        var held = TerminalHeldFrame()
        held.hold(volatile: true, in: renderer)
        purge(frame)

        #expect(held.beginRead(from: renderer) == nil)
        #expect(held.frame == nil)
        #expect(renderer.presentations == [.hidden, .purge])

        held.hold(volatile: false, in: renderer)
        #expect(renderer.presentations == [.hidden, .purge, .shown])
        #expect(renderer.presenting && renderer.queuedFrame, "shown again, it waits for a fresh frame")
    }

    @Test func aReadOfADrawingSurfaceGetsItsPresentedFrameAsItIs() throws {
        let frame = try drawable()
        let renderer = Renderer(presenting: frame)
        var held = TerminalHeldFrame()

        #expect(held.beginRead(from: renderer) === frame)
        #expect(purgeableState(frame) == IOSurface.purgeableNonVolatile)
        #expect(renderer.presentations.isEmpty)
        #expect(held.beginRead(from: Renderer(presenting: nil)) == nil, "nothing before the first draw")
    }

    /// An evicted terminal keeps the renderer's presented frame itself, volatile: no copy.
    @Test func aLastFrameKeepsTheRenderersPresentedFrame() throws {
        let frame = try drawable()
        let last = try #require(TerminalLastFrame(presentedBy: Renderer(presenting: frame)))
        #expect(last.bytes == frame.allocationSize)
        #expect(last.isVolatile)
        #expect(purgeableState(frame) == IOSurface.purgeableVolatile)
        #expect(last.take() === frame)
        #expect(TerminalLastFrame(presentedBy: Renderer(presenting: nil)) == nil)
    }
}
