import AppKit
import Dispatch
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Foundation
import Testing

/// ghostty-integration-DESIGN.md G9: a terminal's echo reaches the screen while the app's main thread is
/// busy. Output is parsed off main (G4); the frame used to reach the layer only through a main-queue block,
/// so a main thread blocked 100 ms held the echo 100 ms. A frame that changes only content now goes to the
/// layer from the renderer's completion thread: the layer's contents change while main is blocked.
@MainActor @Suite(.serialized) struct TerminalEchoOffMainTests {
    @Test func anEchoReachesTheLayerWhileTheMainThreadIsBlocked() async throws {
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
        session.view.frame = host.bounds
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        let layer = try #require(session.surfaceView.layer)

        // The first frame lands through main (a new size always does): a KVO change of the contents.
        io.send(.output(Data("$ ".utf8)))
        await Self.nextContents(of: layer)
        let first = try #require(session.surfaceView.presentedFrame)

        // The echo of a key while main is blocked: its frame must reach the layer meanwhile.
        let changed = ContentsSignal()
        let observation = layer.observe(\.contents, options: [.new]) { _, _ in changed.signal() }
        defer { observation.invalidate() }
        io.send(.output(Data("ls\r\n".utf8)))
        let reached = changed.wait(seconds: 2) // blocks the main thread
        #expect(reached, "the echo's frame waited for the main thread")
        #expect(session.surfaceView.presentedFrame !== first, "the layer still shows the frame before the echo")
    }

    /// Returns at the layer's next contents change.
    static func nextContents(of layer: CALayer) async {
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
}

/// A one-way signal any thread may raise; the test's main thread waits on it.
private nonisolated final class ContentsSignal: Sendable {
    // Test-only: the main thread blocks on it to prove the frame needs no main thread.
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() { semaphore.signal() }

    func wait(seconds: Int) -> Bool {
        semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
    }
}
