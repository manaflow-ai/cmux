import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// FRAME OWNER REFACTOR S4 P0 (switch round ab-s4-sw-22, build ada386be): with `motion.frameOwner.terminals` turned on
/// while terminals showed frames and the in-app recorder ran, the app's main thread stopped for good at the first
/// terminal resize, and every RPC timed out after it. The switch-OFF films of the same build worked.
///
/// A real Ghostty surface (its renderer thread, Metal and the GPU completion thread) in a window on screen, as in the
/// films: the switch goes on at runtime, after the first frame; resizes land; then the terminal keeps drawing at
/// that size (output and a blinking cursor: frames that go to the screen off the main thread). The main thread must
/// keep turning. A sampler thread pings it every 250 ms. When a ping gets no answer within 3 s, the sampler samples
/// this process (`/usr/bin/sample`, every thread's stack), writes the sample to stderr and ends the process with exit
/// code 70. So a hang fails the step with the stacks, and never waits for the runner's stall limit.
///
/// It needs a window server session: run it on a display worker (`cmux-ci run --display --label gui-session-v1`).
@MainActor @Suite(.serialized, .closesItsWindows,
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalFrameOwnerMainThreadTests {
    /// With the films' recorder load (sample 1 of the hung build did not hang without it): inside the main thread's own
    /// Core Animation commit, every turn, a 1-point layer reads the terminal layer's contents and bounds under
    /// `[CATransaction lock]`, as the in-app trace sampler and commit probe do while a film records. A property change
    /// makes main commit every turn. Sample 4 of the hung app (pixel-perfect, STATUS 9732): main in
    /// `CA::Transaction::commit > commit_transaction > _os_unfair_lock_lock_slow`, the Metal completion thread in
    /// Ghostty's off-main present (`setSurfaceOffMain`, which committed while it held `[CATransaction lock]`).
    @Test func theMainThreadKeepsTurningUnderTheRecordersPerCommitLayerReads() async throws {
        let sampler = HangSampler(deadline: .seconds(3))
        sampler.start()
        defer { sampler.stop() }
        let fixture = try await Fixture()
        defer { fixture.close() }
        let reader = LockingReaderLayer()
        reader.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        reader.target = fixture.session.surfaceView.layer
        try #require(fixture.container.layer != nil, "the container has no layer")
        fixture.container.layer?.addSublayer(reader)
        defer { reader.removeFromSuperlayer() }

        let on = TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(true))
        try #require(on == .bool(true), "the switch motion.frameOwner.terminals is not registered")
        let offMainBefore = fixture.offMainPresents
        // Three resizes, each followed by output, with the reader in every main commit.
        for (index, width) in [CGFloat(520), 560, 500].enumerated() {
            fixture.container.terminalWidth = width
            fixture.container.needsLayout = true
            for turn in 0..<180 {
                if turn % 6 == 0 { fixture.io.send(.output(Data("resize \(index) line \(turn)\r\n".utf8))) }
                reader.setNeedsDisplay()
                reader.opacity = turn % 2 == 0 ? 1 : 0.99
                await fixture.commits(1)
            }
        }
        #expect(reader.reads > 0, "the reader never ran inside a commit")
        #expect(fixture.offMainPresents > offMainBefore,
                "no frame went to the screen off the main thread (host_off_main_presents \(offMainBefore) -> \(fixture.offMainPresents))")
        #expect(fixture.session.surfaceView.frame.width == 500, "the terminal is \(fixture.session.surfaceView.frame.width) pt wide")
    }

    /// The window's content: its `layout()` gives the terminal the width asked for, as a pane's layout does.
    final class ResizingContainer: NSView {
        var terminalWidth: CGFloat = 600
        weak var terminal: NSView?

        override func layout() {
            super.layout()
            terminal?.frame = NSRect(x: 0, y: 0, width: terminalWidth, height: 300)
        }
    }

    final class Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let container: ResizingContainer
        private let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            TunableStore.shared.activate(file: nil)
            TunableStore.shared.register(TerminalDragTunables.all)
            // The switch starts off, as in the films; ``close()`` resets it.
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, .bool(false))
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            session = TerminalSession(io: io)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            container = ResizingContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = container
            container.terminal = session.view
            container.addSubview(session.view)
            window.orderFrontRegardless()
            guard session.surfaceView.surface != nil else {
                close()
                try #require(Bool(false), "libghostty created no surface")
                return
            }
            container.layoutSubtreeIfNeeded() // sync-layout: the first size, before the text
            // A prompt-like screen with the cursor shown (it blinks: frames at the shown size).
            io.send(.output(Data("\u{1b}[?25h$ echo ready\r\nready\r\n$ ".utf8)))
            let shown = await waitShown(width: 600)
            if !shown { close() }
            try #require(shown, "the terminal never showed its first frame")
        }

        func close() {
            io.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
            TunableStore.shared.set(TerminalDragTunables.framesOwnedByCommit.key, nil)
        }

        /// Ghostty's frames of this surface that went to the screen off the main thread.
        var offMainPresents: UInt64 {
            guard let surface = session.surfaceView.surface else { return 0 }
            return ghostty_surface_render_counters(surface).host_off_main_presents
        }

        /// Returns after `count` main run-loop turns ended with a Core Animation commit.
        func commits(_ count: Int) async {
            for _ in 0..<count {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CommitBoundary().after { _ in done.resume() }
                }
            }
        }

        /// Waits, commit by commit (at most 10 s), until the shown frame is `width` points wide at the layer's scale.
        func waitShown(width: CGFloat) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                let scale = session.surfaceView.layer?.contentsScale ?? 2
                if let frame = session.surfaceView.presentedFrame, frame.width == Int((width * scale).rounded()) { return true }
                await commits(1)
            }
            return false
        }
    }
}

/// Pings the main thread from a background queue. A ping that gets no answer within `deadline` samples this process
/// (`/usr/bin/sample`, 2 s, every thread), writes the sample to stderr and ends the process with exit code 70: a main
/// thread that stopped for good fails the test with its stack. (Not the app's `MainThreadWatchdog`.)
private nonisolated final class HangSampler: Sendable {
    private let deadline: DispatchTimeInterval
    private let stopped = DispatchSemaphore(value: 0)
    private let running = Mutex<Bool>(false)

    init(deadline: DispatchTimeInterval) {
        self.deadline = deadline
    }

    func start() {
        running.withLock { $0 = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in watch() }
    }

    func stop() {
        running.withLock { $0 = false }
        stopped.signal()
    }

    private func watch() {
        // wakeup-allow: a test's hang sampler: one ping per 250 ms on a background queue, only while its test runs
        while running.withLock({ $0 }) {
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + deadline) == .timedOut, running.withLock({ $0 }) { sampleAndExit() }
            // The next ping in 250 ms, or at once when the test stops the watchdog.
            _ = stopped.wait(timeout: .now() + .milliseconds(250))
        }
    }

    private func sampleAndExit() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = NSTemporaryDirectory() + "main-thread-hang-\(pid).txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(pid), "2", "-file", file]
        try? sample.run()
        // concurrency-allow: the sampler's background queue, after the main thread was seen stopped; it waits for sample
        sample.waitUntilExit()
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "sample did not run"
        FileHandle.standardError.write(Data("MAIN THREAD HANG (S4 frame owner): the main thread did not answer in 3 s. sample of pid \(pid):\n\(text)\n".utf8))
        exit(70)
    }
}

/// Reads its target layer's contents and bounds under `[CATransaction lock]` each time Core Animation displays it,
/// inside a commit (the films' trace sampler and commit probe).
private nonisolated final class LockingReaderLayer: CALayer {
    weak var target: CALayer?
    private(set) var reads = 0

    override func display() {
        CATransaction.lock()
        _ = target?.contents
        _ = target?.bounds
        reads += 1
        CATransaction.unlock()
    }

    override func action(forKey event: String) -> (any CAAction)? { nil }
}
