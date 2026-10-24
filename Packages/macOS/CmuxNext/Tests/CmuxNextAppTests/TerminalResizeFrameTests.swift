import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CoreFoundation
import IOSurface
import Testing

/// ghostty-integration-DESIGN.md G1: a resized terminal's frame at its new size (the text reflowed)
/// goes into the Core Animation commit that carries the size whenever the renderer thread has drawn it
/// by then, and the main thread never waits for it. A host-sized Ghostty layer gets no display pass for
/// a size change; the renderer delivers its frame with a main-queue block, which runs only after the
/// commit when the turn's own display work (other views, other terminals) outlasts the draw.
@MainActor @Suite(.serialized) struct TerminalResizeFrameTests {
    /// A turn whose display work outlasts the renderer's draw (a STRESS layout): the commit carries the
    /// frame at the new size, not the old frame clipped or padded.
    @Test func aSlowTurnsCommitCarriesTheFrameAtTheNewSize() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        var misses: [String] = []
        for step in 1...6 {
            // The display work of this turn: 30 ms just ahead of the commit, after the resize.
            Self.slowTurn(milliseconds: 30)
            let shipped = await fixture.resize(width: 600 - CGFloat(step) * 20)
            if let miss = shipped { misses.append("step \(step): \(miss)") }
        }
        #expect(misses.isEmpty, "\(misses)")
    }

    struct Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = host
            session.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            host.addSubview(session.view)
            window.orderFrontRegardless()
            session.view.layoutSubtreeIfNeeded()
            let text = (0..<12).map { "line \($0) " + String(repeating: "x", count: 50) }.joined(separator: "\r\n")
            io.send(.output(Data(text.utf8)))
            // The renderer's first frame lands on the layer: a KVO change of its contents, no clock.
            let layer = try #require(session.surfaceView.layer)
            if session.surfaceView.presentedFrame == nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var observation: NSKeyValueObservation?
                    observation = layer.observe(\.contents, options: [.new]) { _, _ in
                        guard observation != nil else { return }
                        observation?.invalidate()
                        observation = nil
                        continuation.resume()
                    }
                }
            }
            try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        }

        func close() {
            io.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        }

        /// Resizes the terminal to `width` in one turn; nil when that turn's commit carried the frame at
        /// the new size, else what it carried.
        func resize(width: CGFloat) async -> String? {
            session.view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            session.view.layoutSubtreeIfNeeded()
            let wanted = session.surfaceView.convertToBacking(session.surfaceView.bounds.size)
            let shipped = await TerminalResizeFrameTests.afterCommit { session.surfaceView.presentedFrame.map { ($0.width, $0.height) } }
            guard shipped?.0 != Int(wanted.width) || shipped?.1 != Int(wanted.height) else { return nil }
            return "commit carried \(shipped.map { "\($0.0)x\($0.1)" } ?? "none"), size \(Int(wanted.width))x\(Int(wanted.height))"
        }
    }

    /// Runs `read` in a one-shot observer just after this turn's Core Animation commit (order
    /// 2,000,000; ``CommitBoundary`` uses the same order) and returns its value.
    static func afterCommit<T>(_ read: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, 2_000_001) { observer, _ in
                CFRunLoopObserverInvalidate(observer)
                // main-proof: added to the main run loop only (below).
                MainActor.assumeIsolated { continuation.resume(returning: read()) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    /// Makes the next turn's display work take `milliseconds` just ahead of the commit (a one-shot
    /// observer at order 1,999,000): the renderer finishes its frame meanwhile, and its main-queue
    /// delivery waits for the next turn.
    static func slowTurn(milliseconds: UInt32) {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, 1_999_000) { observer, _ in
            CFRunLoopObserverInvalidate(observer)
            usleep(milliseconds * 1_000) // test: the turn's own display work, the condition under test
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
}
