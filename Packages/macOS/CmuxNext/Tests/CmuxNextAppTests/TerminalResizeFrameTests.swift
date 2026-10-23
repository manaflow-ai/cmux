import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CoreFoundation
import IOSurface
import Testing

/// ghostty-integration-DESIGN.md G1: the Core Animation commit that carries a terminal's new size
/// carries its frame at that size (the text reflowed), not the last frame of the old size clipped
/// or padded. A host-sized Ghostty layer gets no display pass for a size change, so the frame must
/// be presented before that commit; this reads the layer in the observer right after the commit.
@MainActor @Suite(.serialized) struct TerminalResizeFrameTests {
    @Test func theCommitOfANewSizeCarriesTheFrameAtThatSize() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = host
        session.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        let text = (0..<12).map { "line \($0) " + String(repeating: "x", count: 50) }.joined(separator: "\r\n")
        io.send(.output(Data(text.utf8)))
        let drawnBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < drawnBy, session.surfaceView.presentedFrame == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        try await Task.sleep(for: .milliseconds(200)) // test: the first frames settle before the resizes

        var misses: [String] = []
        for step in 1...8 {
            let width = 600 - CGFloat(step) * 20
            session.view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            session.view.layoutSubtreeIfNeeded()
            let wanted = session.surfaceView.convertToBacking(session.surfaceView.bounds.size)
            let shipped = await Self.afterCommit { session.surfaceView.presentedFrame.map { ($0.width, $0.height) } }
            if shipped?.0 != Int(wanted.width) || shipped?.1 != Int(wanted.height) {
                misses.append("step \(step): commit carried \(shipped.map { "\($0.0)x\($0.1)" } ?? "none"), size \(Int(wanted.width))x\(Int(wanted.height))")
            }
            try await Task.sleep(for: .milliseconds(50)) // test: one resize per turn, as a drag frame
        }
        #expect(misses.isEmpty, "\(misses)")
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
}
