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
        let setupStarted = ContinuousClock.now
        let fixture = try await Fixture()
        defer { fixture.close() }
        var timings = ["setup \(Self.ms(setupStarted.duration(to: .now)))"]
        let reader = LockingReaderLayer()
        reader.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        reader.target = fixture.session.surfaceView.layer
        try #require(fixture.container.layer != nil, "the container has no layer")
        fixture.container.layer?.addSublayer(reader)
        defer { reader.removeFromSuperlayer() }

        sampler.enter("switch on and resizes")
        let offMainBefore = fixture.offMainPresents
        // Three resizes, each followed by 2 s of wall-clock time with output every few milliseconds (frames at the
        // shown size, which go off main once the presenter reported the landing's commit), and the reader in every
        // main commit. The hang came in the films within a second of the first resize.
        for (index, width) in [CGFloat(520), 560, 500].enumerated() {
            fixture.container.terminalWidth = width
            fixture.container.needsLayout = true
            let started = ContinuousClock.now
            let until = started.advanced(by: .seconds(2))
            var line = 0, toggle = false, commits = 0
            var lastOutput = ContinuousClock.now
            var longestCommit = Duration.zero
            while ContinuousClock.now < until {
                if lastOutput.duration(to: .now) >= .milliseconds(4) {
                    fixture.io.send(.output(Data("resize \(index) line \(line)\r\n".utf8)))
                    line += 1
                    lastOutput = .now
                }
                toggle.toggle()
                reader.setNeedsDisplay()
                reader.opacity = toggle ? 1 : 0.99
                let asked = ContinuousClock.now
                await fixture.commits(1)
                longestCommit = max(longestCommit, asked.duration(to: .now))
                commits += 1
            }
            timings.append("\(Int(width)) pt: \(Self.ms(started.duration(to: .now))), \(commits) commits, longest \(Self.ms(longestCommit))")
        }
        let stats = TerminalFramePresenter.forWindow(fixture.window).stats
        print("S4 hang case: \(timings.joined(separator: "; ")); presenter \(stats)")
        let stalls = await sampler.finish()
        // Making the first surface on a cold worker (fonts, shaders) is not this case's phase: reported, not failed.
        for stall in stalls where stall.phase == "setup" { print("S4 hang case: main stalled \(stall) (its sample is in the log)") }
        let caseStalls = stalls.filter { $0.phase != "setup" }
        #expect(caseStalls.isEmpty, "the main thread stopped for more than 3 s and came back: \(caseStalls) (each sample is in the log); \(timings.joined(separator: "; "))")
        #expect(reader.reads > 0, "the reader never ran inside a commit")
        #expect(fixture.offMainPresents > offMainBefore,
                "no frame went to the screen off the main thread (host_off_main_presents \(offMainBefore) -> \(fixture.offMainPresents))")
        #expect(fixture.session.surfaceView.frame.width == 500, "the terminal is \(fixture.session.surfaceView.frame.width) pt wide")
    }

    /// `duration` in milliseconds, for messages.
    nonisolated static func ms(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f ms", ms)
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
            // The switch starts off (the pre-m19 default the films used); ``close()`` resets it.
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

/// Pings the main thread from a background queue every 250 ms. A ping with no answer within `deadline` samples this
/// process (`/usr/bin/sample`, 2 s, every thread) and writes the sample to stderr. A main thread still stopped after the
/// sample ends the process with exit code 70 (a hang fails the step with its stack and never waits for the runner's
/// stall limit). One that answered meanwhile is a stall: its length is recorded, and the test fails on it
/// (``finish()``). (Not the app's `MainThreadWatchdog`.)
private nonisolated final class HangSampler: Sendable {
    /// A stop of the main thread longer than the deadline that ended, and the test's phase it began in.
    struct Stall: Sendable, CustomStringConvertible {
        var phase: String
        var duration: Duration
        var description: String { "\(TerminalFrameOwnerMainThreadTests.ms(duration)) in \(phase)" }
    }

    private struct State {
        var running = false
        var ended = false
        var phase = "setup"
        var stalls: [Stall] = []
        /// ``finish()``, waiting for the watcher to end (a sample in progress included).
        var onEnd: CheckedContinuation<Void, Never>?
        /// When the main thread ran the latest ping (nil until it did).
        var answeredAt: ContinuousClock.Instant?
    }

    private let deadline: Duration
    private let stopped = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    init(deadline: Duration) {
        self.deadline = deadline
    }

    func start() {
        state.withLock { $0.running = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in watch() }
    }

    /// Stops the watcher (an early exit of the test). ``finish()`` also waits for it.
    func stop() {
        state.withLock { $0.running = false }
        stopped.signal()
    }

    /// The test's phase from now on: each stall names the phase it began in.
    func enter(_ phase: String) {
        state.withLock { $0.phase = phase }
    }

    /// Stops the watcher and returns, once it ended (after a sample in progress), the stalls it saw.
    func finish() async -> [Stall] {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let endedAlready = state.withLock { state -> Bool in
                state.running = false
                if !state.ended { state.onEnd = done }
                return state.ended
            }
            stopped.signal()
            if endedAlready { done.resume() }
        }
        return state.withLock { $0.stalls }
    }

    private var running: Bool { state.withLock { $0.running } }

    private func watch() {
        // wakeup-allow: a test's hang sampler: one ping per 250 ms on a background queue, only while its test runs
        while running {
            let answered = DispatchSemaphore(value: 0)
            // The previous ping answered (or the process ended): no late answer overwrites this one's.
            state.withLock { $0.answeredAt = nil }
            let pinged = ContinuousClock.now
            let phase = state.withLock { $0.phase }
            DispatchQueue.main.async { [self] in
                state.withLock { $0.answeredAt = .now }
                answered.signal()
            }
            let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
            if answered.wait(timeout: .now() + seconds) == .timedOut, running {
                let sample = takeSample()
                // concurrency-allow: the sampler's background queue; zero timeout, only reads whether main answered
                if answered.wait(timeout: .now()) == .timedOut {
                    write("MAIN THREAD HANG (S4 frame owner): the main thread did not answer in \(seconds) s and is still stopped after the sample:\n\(sample)")
                    exit(70)
                }
                let stall = pinged.duration(to: state.withLock { $0.answeredAt } ?? .now)
                write("MAIN THREAD STALL (S4 frame owner, \(phase)): the main thread answered after \(stall), longer than \(seconds) s. Sample taken during the stall:\n\(sample)")
                state.withLock { $0.stalls.append(Stall(phase: phase, duration: stall)) }
            }
            // The next ping in 250 ms, or at once when the test stops the watcher.
            _ = stopped.wait(timeout: .now() + .milliseconds(250))
        }
        let onEnd = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.ended = true
            defer { state.onEnd = nil }
            return state.onEnd
        }
        onEnd?.resume()
    }

    /// This process's threads, sampled for 2 s.
    private func takeSample() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = NSTemporaryDirectory() + "main-thread-hang-\(pid)-\(UUID().uuidString).txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(pid), "2", "-file", file]
        try? sample.run()
        // concurrency-allow: the sampler's background queue, after the main thread was seen stopped; it waits for sample
        sample.waitUntilExit()
        return (try? String(contentsOfFile: file, encoding: .utf8)) ?? "sample did not run"
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
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
