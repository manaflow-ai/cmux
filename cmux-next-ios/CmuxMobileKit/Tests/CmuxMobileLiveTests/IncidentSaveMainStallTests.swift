@testable import CmuxMobileLive
import Foundation
import QuartzCore
import XCTest

/// Leo, 2026-11-24: "im also still noticing in intervals lag spikes when just typing on phone. we cant be
/// exposing that kind of stuff. im just lte connecting to my mac and all".
///
/// Suspect B: while an incident is open (an LTE blip opens one), the reporter's 5 s tick rewrote its outbox
/// file, an encode and an atomic file-protected write, on the main thread. This bench opens an incident
/// whose report cannot be sent (the phone's link to the service is down too), lets the reporter tick on its
/// real 5 s clock for `seconds`, and times main's turns with a 4 ms timer; then it times `tick()` itself
/// `calls` times. The "before" leg runs the old save (encode and atomic write on main) for the same outbox
/// file at the same points. It prints one line `INCIDENTSAVE …` per leg. XCTest so the Linux pool runs it.
final class IncidentSaveMainStallTests: XCTestCase {
    static let seconds: Double = ProcessInfo.processInfo.environment["CMUX_INCIDENT_STALL_SECONDS"].flatMap(Double.init) ?? 60
    static let calls = 300
    static let stallMs = 50.0

    final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        func get() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    struct Offline: Error {}

    @MainActor
    func testTheFiveSecondSaveLeavesMainFree() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "incident-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Now()
        let app = ConnectivityIncidentApp(version: "1.2.0", build: "7", config: "TestFlight", simulator: false, model: "iPhone17,4", os: "27.2")
        let reporter = ConnectivityIncidentReporter(file: file, app: app, now: { now.get() }, isTeam: { true },
                                                    check: { (true, true) },
                                                    send: { _, _, _ in throw Offline() })
        // The app in front and a Mac that does not answer for 40 s: one incident opens and stays open.
        reporter.appActive(true)
        reporter.link(macID: "m1", name: "Studio", .trying(transport: "wireguard", reason: nil, newDial: true))
        for _ in 0..<8 {
            now.advance(5)
            reporter.link(macID: "m1", name: "Studio", .trying(transport: "wireguard", reason: "dial timed out", newDial: false))
            reporter.tick()
            await Task.yield()
        }
        let deadline = CACurrentMediaTime() + 5
        while reporter.pending.isEmpty, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: waits for the reporter's send task
        }
        XCTAssertFalse(reporter.pending.isEmpty, "no incident opened")
        await ConnectivityIncidentReporter.savesWritten()
        let bytes = (try? Data(contentsOf: file).count) ?? 0
        XCTAssertGreaterThan(bytes, 0, "the outbox was not written")

        // After: the reporter's own 5 s ticks (real clock), main timed throughout.
        let after = try await leg(name: "after") { reporter.tick() }
        // Before: the old save on main, at the same points, for the same outbox.
        let outbox = try JSONDecoder().decode(ConnectivityIncidentOutbox.self, from: Data(contentsOf: file))
        reporter.appActive(false)
        let before = try await leg(name: "before") {
            reporter.tick()
            guard let data = try? JSONEncoder().encode(outbox) else { return }
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        for line in [before, after] {
            let report = "INCIDENTSAVE \(line) outbox_bytes=\(bytes) duress=incident_open_send_failing"
            print(report)
            let attachment = XCTAttachment(string: report)
            attachment.name = "incident-save-main-stalls.txt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // The Linux pool's run.log and junit keep a skip's message but drop stdout and attachments, so the rows
        // ride out as one. A failed assertion above still fails the test.
        throw XCTSkip(["INCIDENTSAVE \(before)", "INCIDENTSAVE \(after)"].joined(separator: " | "))
    }

    /// `seconds` of main turns timed while `work` runs every 5 s on a main timer, then `calls` timed calls.
    @MainActor
    func leg(name: String, work: @escaping @MainActor () -> Void) async throws -> String {
        let sampler = TurnSampler(stallMs: Self.stallMs)
        let ticker = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(ticker, forMode: .common)
        sampler.begin()
        try await Task.sleep(for: .seconds(Self.seconds)) // test: the real 5 s clock runs
        ticker.invalidate()
        sampler.end()
        var costs: [Double] = []
        for _ in 0..<Self.calls {
            let start = CACurrentMediaTime()
            work()
            costs.append((CACurrentMediaTime() - start) * 1000)
            await Task.yield()
        }
        await ConnectivityIncidentReporter.savesWritten()
        costs.sort()
        func pct(_ q: Double) -> Double { costs[min(costs.count - 1, Int((Double(costs.count - 1) * q).rounded()))] }
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        return "leg=\(name) seconds=\(Int(Self.seconds)) turns=\(sampler.turns) stalls_over_50ms=\(sampler.stalls) "
            + "worst_gap_ms=\(f(sampler.worstGapMs)) calls=\(costs.count) main_ms_p50=\(f(pct(0.5))) "
            + "main_ms_p99=\(f(pct(0.99))) main_ms_max=\(f(costs.last ?? 0)) calls_over_50ms=\(costs.filter { $0 > Self.stallMs }.count)"
    }

    /// A 4 ms repeating timer on main: a turn more than `stallMs` late is a stall.
    @MainActor final class TurnSampler {
        static let period = 0.004
        let stallMs: Double
        private var timer: Timer?
        private var last: CFTimeInterval = 0
        private(set) var stalls = 0
        private(set) var turns = 0
        private(set) var worstGapMs: Double = 0
        init(stallMs: Double) { self.stallMs = stallMs }
        func begin() {
            last = CACurrentMediaTime()
            let timer = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.turn() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        func end() { timer?.invalidate(); timer = nil }
        private func turn() {
            let now = CACurrentMediaTime()
            let gap = max(0, (now - last - Self.period) * 1000)
            if gap > stallMs { stalls += 1 }
            worstGapMs = max(worstGapMs, gap)
            last = now
            turns += 1
        }
    }
}
