#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import QuartzCore
import UIKit
import XCTest
@testable import CmuxMobileTerminal
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// Leo, 2026-11-24: "im also still noticing in intervals lag spikes when just typing on phone. we cant be
/// exposing that kind of stuff. im just lte connecting to my mac and all".
///
/// Five minutes of typing through the real screen (`TerminalViewController` and its Ghostty surface) with
/// the screen's real timers, while a warm tab behind it streams a build log (suspect A: the hidden page's
/// 1 s feed of up to `hiddenFeedBudget` bytes). Keys go in at 10 a second through the surface's
/// `insertText`, and the Mac's echo comes back 80 ms later (LTE, 10% jitter) on the main queue.
///
/// A 4 ms timer on the main run loop times every turn; a turn that came more than 50 ms late is a stall,
/// tagged with what ran during it (`hidden-batch`: the warm tab handed Ghostty a batch). It prints one line
/// `MAINSTALL …` with the stall count, the worst stall, the hidden batches' own main-thread gaps and the
/// echoes' lateness, and records it as an attachment. XCTest (not Swift Testing) so the Linux pool's
/// runner runs it.
final class TypingMainStallTests: XCTestCase {
    static let typingSeconds: Double = ProcessInfo.processInfo.environment["CMUX_TYPING_STALL_SECONDS"].flatMap(Double.init) ?? 300
    static let keyInterval = 0.1
    static let rttMs = 80.0
    static let stallMs = 50.0

    /// The shown tab: echoes each key after an LTE round trip, and times how late main ran the echo.
    @MainActor final class EchoSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var keys = 0
        /// How late the main queue ran each echo past its due time (ms).
        private(set) var lateness: [Double] = []
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {
            keys += 1
            let rtt = TypingMainStallTests.rttMs * Double.random(in: 0.9...1.1) / 1000
            let due = CACurrentMediaTime() + rtt
            DispatchQueue.main.asyncAfter(deadline: .now() + rtt) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lateness.append(max(0, (CACurrentMediaTime() - due) * 1000))
                    self.handler?(.output(bytes))
                }
            }
        }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func setOutputPaused(_ paused: Bool) {}
        func write(_ data: Data) { handler?(.output(data)) }
    }

    /// The warm tab behind it: a Mac terminal whose output the test writes.
    @MainActor final class StreamSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var paused = false
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func setOutputPaused(_ paused: Bool) { self.paused = paused }
        func write(_ data: Data) { handler?(.output(data)) }
    }

    @MainActor
    func testFiveMinutesOfTypingWhileAWarmTabStreams() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        #if canImport(CmuxMobileLinkFFI)
        resetKeyPaint()
        #endif

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let echo = EchoSession()
        let shown = Self.screen(echo, title: "typing", in: root, window: window)
        let stream = StreamSession()
        let warm = Self.screen(stream, title: "build", in: root, window: window)
        try await Self.waitUntil(5) { echo.handler != nil && stream.handler != nil && shown.surface.surface != nil && warm.surface.surface != nil }
        XCTAssertNotNil(shown.surface.surface, "libghostty created no surface for the shown tab")
        XCTAssertNotNil(warm.surface.surface, "libghostty created no surface for the warm tab")
        echo.write(Data("ready\r\n$ ".utf8))
        stream.write(Data("build\r\n".utf8))
        try await Self.waitUntil(3) { shown.surface.screenText()?.contains("ready") == true }
        // The warm tab goes behind: out of the window, as a tab behind the shown one is.
        warm.view.removeFromSuperview()
        shown.view.superview?.bringSubviewToFront(shown.view)
        try await Task.sleep(for: .milliseconds(300)) // test: the hide's own work settles

        let warmBatchesBefore = warm.outputCounts.batches
        let sampler = MainTurnSampler(stallMs: Self.stallMs) { ["hidden-batch": warm.outputCounts.batches] }
        // A busy build in the warm tab: 32 lines of about 64 bytes every 10 ms (about 200 KB/s).
        var line = 0
        var streamed = 0
        let feeder = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !stream.paused else { return }
                let chunk = Data((line..<line + 32).map { "log \($0) " + String(repeating: "x", count: 48) + "\r\n" }.joined().utf8)
                line += 32
                streamed += chunk.count
                stream.write(chunk)
            }
        }
        RunLoop.main.add(feeder, forMode: .common)
        sampler.begin()

        let start = CACurrentMediaTime()
        var typed = 0
        while CACurrentMediaTime() - start < Self.typingSeconds {
            shown.surface.insertText(String(Character(UnicodeScalar(UInt8(97 + typed % 26)))))
            typed += 1
            try await Task.sleep(for: .milliseconds(Int(Self.keyInterval * 1000))) // test: steady typing rate
        }
        try await Self.waitUntil(2) { echo.lateness.count >= echo.keys }
        feeder.invalidate()
        sampler.end()

        let stalls = sampler.stalls
        let hiddenStalls = stalls.filter { $0.tags.contains("hidden-batch") }
        let batchGaps = sampler.taggedGaps["hidden-batch", default: []].sorted()
        let late = echo.lateness.sorted()
        #if canImport(CmuxMobileLinkFFI)
        let paint = keyPaintSnapshot().replacingOccurrences(of: "\n", with: " | ")
        #else
        let paint = "n/a"
        #endif
        let report = "MAINSTALL seconds=\(Int(Self.typingSeconds)) keys=\(typed) sent=\(echo.keys) turns=\(sampler.turns) "
            + "stalls_over_50ms=\(stalls.count) worst_stall_ms=\(Self.f(stalls.map(\.ms).max() ?? sampler.worstGapMs)) "
            + "worst_gap_ms=\(Self.f(sampler.worstGapMs)) "
            + "A_hidden_batches=\(warm.outputCounts.batches - warmBatchesBefore) A_streamed_kb=\(streamed / 1024) "
            + "A_stalls_over_50ms=\(hiddenStalls.count) A_batch_gap_ms_p50=\(Self.f(Self.pct(batchGaps, 0.5))) "
            + "A_batch_gap_ms_max=\(Self.f(batchGaps.last ?? 0)) "
            + "echo_late_ms_p50=\(Self.f(Self.pct(late, 0.5))) echo_late_ms_p99=\(Self.f(Self.pct(late, 0.99))) "
            + "echo_late_ms_max=\(Self.f(late.last ?? 0)) "
            + "stalls=[\(stalls.prefix(40).map { "\(Self.f($0.at))s:\(Self.f($0.ms))ms:\($0.tags.joined(separator: "+"))" }.joined(separator: ","))] "
            + "keypaint=[\(paint)] duress=lte_rtt80ms_jitter10pct_warm_tab_200KBps"
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "typing-main-stalls.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(echo.keys, typed, "every key reached the session")
        XCTAssertGreaterThan(warm.outputCounts.batches - warmBatchesBefore, 0, "the warm tab fed no batch")
        // The Linux pool's run.log and junit keep a skip's message but drop stdout and attachments, so the row
        // rides out as one. A failed assertion above still fails the test.
        throw XCTSkip(report)
    }

    // MARK: Harness

    @MainActor
    static func screen(_ session: some TerminalSession, title: String, in root: UIViewController, window: UIWindow) -> TerminalViewController {
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: title)
        let screen = TerminalViewController(model: model)
        root.addChild(screen)
        screen.view.frame = window.bounds
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        return screen
    }

    @MainActor
    static func waitUntil(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + seconds
        while !condition(), CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    static func pct(_ sorted: [Double], _ q: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    static func f(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// Times the main run loop's turns: a 4 ms repeating timer on main, in the common modes. A turn more than
/// `stallMs` past its due time is a stall, tagged with the counters `counts` reports changed during it.
@MainActor final class MainTurnSampler {
    struct Stall { let at: Double; let ms: Double; let tags: [String] }
    static let period = 0.004
    private let stallMs: Double
    private let counts: @MainActor () -> [String: Int]
    private var timer: Timer?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var lastCounts: [String: Int] = [:]
    private(set) var stalls: [Stall] = []
    /// Every turn's lateness (ms) in which a counter changed, by counter.
    private(set) var taggedGaps: [String: [Double]] = [:]
    private(set) var turns = 0
    private(set) var worstGapMs: Double = 0

    init(stallMs: Double, counts: @escaping @MainActor () -> [String: Int]) {
        self.stallMs = stallMs
        self.counts = counts
    }

    func begin() {
        start = CACurrentMediaTime()
        last = start
        lastCounts = counts()
        let timer = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.turn() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    private func turn() {
        let now = CACurrentMediaTime()
        let gap = max(0, (now - last - Self.period) * 1000)
        let current = counts()
        let changed = current.keys.filter { current[$0] != lastCounts[$0] }.sorted()
        for tag in changed { taggedGaps[tag, default: []].append(gap) }
        if gap > stallMs { stalls.append(Stall(at: now - start, ms: gap, tags: changed)) }
        worstGapMs = max(worstGapMs, gap)
        last = now
        lastCounts = current
        turns += 1
    }
}
#endif
