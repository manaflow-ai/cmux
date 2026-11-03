import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import IOSurface
import Testing

/// SWITCH FRAMES item 2, the lead's memory rule: a saved frame the person cannot see is the system's to reclaim under
/// memory pressure, as Chrome discards a hidden tab's content. An evicted terminal's last frame on its new surface's own
/// layer is volatile while that surface is hidden and has not drawn, and non-volatile again before it shows. A frame the
/// system purged meanwhile is never left on screen: the surface takes the cold path (it draws its own frame) at once.
@Suite(.serialized, .closesItsWindows)
@MainActor struct SavedFramePurgeTests {
    /// kIOSurfacePurgeable* by value (IOSurfaceTypes.h; the imported Swift names differ by SDK).
    static let nonVolatile: UInt32 = 0, volatile: UInt32 = 1, empty: UInt32 = 2, keepCurrent: UInt32 = 3

    /// Sets `surface`'s purgeable state; returns the state it had. IOSurface is toll-free bridged with IOSurfaceRef (in a
    /// test file with Foundation, `IOSurface` is the Foundation class, which IOSurfaceSetPurgeable does not take).
    @discardableResult
    static func setPurgeable(_ surface: IOSurface, _ state: UInt32) -> UInt32 {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(unsafeBitCast(surface, to: IOSurfaceRef.self), state, &old)
        return old
    }

    static func state(_ surface: IOSurface) -> UInt32 { setPurgeable(surface, keepCurrent) }

    /// An evicted terminal's saved frame, shown again on a new session's surface that is hidden (a warm switch in the
    /// background, a pane off screen): returns the window, both IOs and the new session, and the saved frame.
    static func hiddenSessionShowingASavedFrame() async throws -> (NSWindow, [ScriptedTerminalIO], TerminalSession, IOSurface) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        window.orderFrontRegardless()
        let io = ScriptedTerminalIO(), freshIO = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.view.frame = host.bounds
        host.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(Data("\u{1b}[2J\u{1b}[Hsaved screen\r\nline 2\r\n".utf8)))
        try await EvictedTerminalRevealFrameTests.drawn(session)
        session.isRenderingSuspended = true
        var frames = TerminalLastFrames()
        frames.evict(session, key: "tab", capacity: 8, atOnce: false)
        session.view.removeFromSuperview()
        session.close()

        let fresh = TerminalSession(io: freshIO)
        fresh.view.frame = host.bounds
        host.addSubview(fresh.view)
        fresh.view.layoutSubtreeIfNeeded()
        fresh.isRenderingSuspended = true // hidden: the person cannot see it
        frames.show("tab", on: fresh)
        try #require(fresh.showsHeldFrame, "setup: the hidden session shows no saved frame")
        let contents = try #require(fresh.surfaceView.layer?.contents, "setup: the saved frame is not on the surface's own layer")
        let object = contents as CFTypeRef
        try #require(CFGetTypeID(object) == IOSurfaceGetTypeID(), "setup: the surface's layer shows no IOSurface")
        return (window, [io, freshIO], fresh, unsafeDowncast(object, to: IOSurface.self))
    }

    @Test func aHiddenSurfacesSavedFrameIsPurgeableAndNonVolatileOnceShown() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let (window, ios, fresh, saved) = try await Self.hiddenSessionShowingASavedFrame()
        defer {
            fresh.close()
            ios.forEach { $0.finish() }
            window.close()
        }
        #expect(Self.state(saved) == Self.volatile, "a hidden surface's saved frame is not reclaimable under memory pressure")

        fresh.isRenderingSuspended = false // shown
        #expect(Self.state(saved) == Self.nonVolatile, "the saved frame shows while its pages may be purged")
        #expect((fresh.surfaceView.layer?.contents as CFTypeRef?) === saved, "shown again, the surface does not show its saved frame")
        #expect(fresh.diagnostics.drawing == false, "the surface draws its empty grid over the saved frame before its content")
    }

    @Test func aPurgedSavedFrameIsNeverLeftOnScreenAndTheSurfaceDrawsItsOwnFrame() async throws {
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let (window, ios, fresh, saved) = try await Self.hiddenSessionShowingASavedFrame()
        defer {
            fresh.close()
            ios.forEach { $0.finish() }
            window.close()
        }
        // Memory pressure while hidden: the system takes the saved frame's pages.
        Self.setPurgeable(saved, Self.empty)

        fresh.isRenderingSuspended = false // shown
        #expect((fresh.surfaceView.layer?.contents as CFTypeRef?) !== saved, "a purged saved frame is on screen: a blank pane")
        #expect(!fresh.surfaceView.showsSavedFrame, "the pane still waits on a purged saved frame instead of the cold path")
        #expect(fresh.diagnostics.drawing == true, "with its saved frame purged the surface does not draw (the cold path)")
        let by = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < by, fresh.surfaceView.presentedFrame == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fresh.surfaceView.presentedFrame != nil && fresh.surfaceView.presentedFrame !== saved,
                "the surface presented no frame of its own after its saved frame was purged")
    }
}
