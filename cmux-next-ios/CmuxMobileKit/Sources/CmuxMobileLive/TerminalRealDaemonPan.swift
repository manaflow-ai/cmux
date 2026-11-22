// DEBUG and Demo builds only: the real-daemon pan bench is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Darwin
import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// DEBUG only. Leo, 2026-11-22 06:04Z: "just off some basic scroll throughs of
/// the tui on my phone, the thing still lags ... why cant you simply scroll
/// through the depiction that was already given?" and 08:05Z: "we should
/// almost always be doing this. always. testing under duress."
///
/// The workspace tab page (`TerminalTabPage`, `DaemonTerminalSession`,
/// `DaemonClient`, Ghostty) attached to a REAL cmux-tui daemon on the
/// simulator's host Mac: the NIGHTLY's own binary, started by
/// RealDaemonPanUITests (`verify/real-daemon-pan/daemon.sh`). Only the link is
/// left out: each `daemon` channel is the daemon's Unix socket itself, the
/// lines cmux-mobile-host would splice. In that daemon a Claude Code-like
/// program (`verify/real-daemon-pan/streamer.py`) prints ROWS styled rows and
/// then streams; the page attaches once they are on the Mac, as a person opens
/// a long session's tab.
///
/// Environment (from the UI test): `CMUX_RDP_SOCKET`, `CMUX_RDP_DIR`,
/// `CMUX_RDP_STREAMER`, `CMUX_RDP_MODE` (`primary` or `alt`), `CMUX_RDP_ROWS`,
/// `CMUX_RDP_PERIOD_MS`. The `debug.real-daemon-pan` label says
/// `rdp-MODE ready ...` once the page is attached and drawn, and
/// `rdp-MODE done KEY=VALUE...` 4 s after the last finger lifts: frames
/// (p50/p95/max ms, hitches over 1.5 periods, stalls over 50 ms) and the
/// main-queue ping (`pingMax`) while a finger was down and 0.6 s after;
/// `attaches` (`attach-surface` sent while measuring: older-history fetches),
/// `vtStates` (replays received: each a reset and a whole-mirror re-render),
/// `omitted` (the last replay's `history_rows_omitted`), `contentJumps`
/// (frames whose document height changed by more than a screen), `yanks`
/// (frames the page landed on its bottom from more than a screen above it
/// while a finger was down), `driftRows` (the largest per-frame offset change,
/// in rows, the finger did not make while it tracked), `wheels` (wheel
/// reports sent), `wheelSeen` (the app's `WHEEL#N` read back) and `rttP50`,
/// `rttMax` (send to the redraw that counted it, ms).
public struct TerminalRealDaemonPanRoot: View {
    @State private var bench = TerminalRealDaemonPan()

    public init() {}

    public static var isRequested: Bool { ProcessInfo.processInfo.environment["CMUX_RDP_SOCKET"] != nil }

    public var body: some View {
        ZStack {
            Color.black
            if let host = bench.host {
                TerminalTabPage(host: host, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0), isInteractive: true)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Text(bench.step)
                .font(.system(size: 2))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.real-daemon-pan")
        }
        .task { await bench.run() }
    }
}

@MainActor @Observable
final class TerminalRealDaemonPan {
    private(set) var host: TerminalTabHost?
    private(set) var step = "start"
    @ObservationIgnored private let stats = RealDaemonPanStats()

    private func mark(_ label: String) {
        step = label
        NSLog("[real-daemon-pan] %@", label)
    }

    func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["CMUX_RDP_SOCKET"], let dir = env["CMUX_RDP_DIR"],
              let streamer = env["CMUX_RDP_STREAMER"] else { return mark("error=env") }
        let mode = env["CMUX_RDP_MODE"] ?? "primary"
        let rows = Int(env["CMUX_RDP_ROWS"] ?? "") ?? 12_000
        let period = Int(env["CMUX_RDP_PERIOD_MS"] ?? "") ?? 16
        stats.tracksWheel = mode == "alt"
        let clock = ContinuousClock()
        let prefix = "rdp-\(mode)"
        let surface: Int
        do {
            let control = DaemonClient(channel: try UnixSocketChannel(path: socket, id: 100, stats: nil))
            let reply = try await control.request("new-workspace", params: ["name": "pan-\(mode)", "cols": 120, "rows": 40])
            guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let data = object["data"] as? [String: Any], let id = data["surface"] as? Int else {
                return mark("\(prefix) error=new-workspace \(String(decoding: reply, as: UTF8.self).prefix(200))")
            }
            surface = id
            try? await clock.sleep(for: .seconds(1))
            let done = "\(dir)/done-\(mode)"
            let command = "exec python3 '\(streamer)' \(mode) \(rows) \(period) '\(done)'\r"
            _ = try await control.request("send", params: ["surface": surface, "bytes": Data(command.utf8).base64EncodedString()])
            mark("\(prefix) history surface=\(surface)")
            let deadline = Date().addingTimeInterval(180)
            while !FileManager.default.fileExists(atPath: done), Date() < deadline {
                try? await clock.sleep(for: .milliseconds(200))
            }
            guard FileManager.default.fileExists(atPath: done) else { return mark("\(prefix) error=no-history") }
        } catch {
            return mark("\(prefix) error=control \(error)")
        }
        try? await clock.sleep(for: .seconds(2))
        let stats = stats
        let session = DaemonTerminalSession(
            surface: surface,
            programName: mode == "alt" ? "claude" : "zsh",
            clientInfo: ["name": "bench iPhone", "kind": "ios", "device_kind": "iphone", "device_name": "bench iPhone"],
            open: { DaemonClient(channel: try UnixSocketChannel(path: socket, id: 1, stats: stats), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
            openInput: { DaemonClient(channel: try UnixSocketChannel(path: socket, id: 2, stats: stats), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) }
        )
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "claude — Mac")
        host = TerminalTabHost(model: model)
        let attachDeadline = Date().addingTimeInterval(60)
        while !model.connectionState.isAttached, Date() < attachDeadline { try? await clock.sleep(for: .milliseconds(100)) }
        guard model.connectionState.isAttached else { return mark("\(prefix) error=attach") }
        try? await clock.sleep(for: .seconds(4))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            return mark("\(prefix) error=window")
        }
        let before = stats.snapshot()
        let meter = RealDaemonPanMeter(window: window)
        mark("\(prefix) ready isTUI=\(model.isTUI) omitted=\(before.omitted) vtStates=\(before.vtStates)")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await clock.sleep(for: .milliseconds(250))
            if let lastUp = meter.lastTouchUp, meter.touchesDown == 0, CACurrentMediaTime() - lastUp > 4 { break }
        }
        meter.stop()
        let after = stats.snapshot()
        let rtts = after.rtts.sorted()
        func ms(_ values: [Double], _ q: Double) -> String {
            values.isEmpty ? "-" : String(format: "%.1f", values[min(values.count - 1, Int(Double(values.count - 1) * q))])
        }
        mark("\(prefix) done " + meter.summary
             + " attaches=\(after.attaches - before.attaches) vtStates=\(after.vtStates - before.vtStates) omitted=\(after.omitted)"
             + " bytesIn=\(after.bytesIn - before.bytesIn) wheels=\(after.wheels - before.wheels) wheelSeen=\(after.wheelSeen)"
             + " rttN=\(rtts.count) rttP50=\(ms(rtts, 0.5)) rttP95=\(ms(rtts, 0.95)) rttMax=\(ms(rtts, 1))"
             + " isTUI=\(model.isTUI)")
    }
}

/// What the bench's channels saw, from their reader threads and senders.
final class RealDaemonPanStats: @unchecked Sendable {
    struct Snapshot {
        var attaches = 0, vtStates = 0, omitted = 0, bytesIn = 0, wheels = 0, wheelSeen = 0
        var rtts: [Double] = []
    }

    private let lock = NSLock()
    private var current = Snapshot()
    /// Send times of wheel reports not yet seen counted by the app, oldest first.
    private var wheelSent: [CFTimeInterval] = []
    var tracksWheel = false

    func snapshot() -> Snapshot { lock.withLock { current } }

    func sent(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cmd = object["cmd"] as? String else { return }
        if cmd == "attach-surface" { lock.withLock { current.attaches += 1 } }
        guard cmd == "send" else { return }
        var bytes = (object["bytes"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        if let text = object["text"] as? String { bytes.append(Data(text.utf8)) }
        let wheels = Self.count(of: Data("\u{1B}[<64;".utf8), in: bytes) + Self.count(of: Data("\u{1B}[<65;".utf8), in: bytes)
        guard wheels > 0 else { return }
        let now = CACurrentMediaTime()
        lock.withLock {
            current.wheels += wheels
            wheelSent.append(contentsOf: repeatElement(now, count: wheels))
        }
    }

    func received(_ line: Data) {
        lock.withLock { current.bytesIn += line.count }
        if line.range(of: Data("vt-state".utf8)) != nil {
            let omitted = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["history_rows_omitted"] as? Int
            lock.withLock {
                current.vtStates += 1
                if let omitted { current.omitted = omitted }
            }
            return
        }
        guard tracksWheel, line.range(of: Data("\"output\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let data = (object["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        // The highest `WHEEL#N` in these bytes: the app counted N wheel reports.
        var seen = -1
        var search = data.startIndex..<data.endIndex
        let tag = Data("WHEEL#".utf8)
        while let found = data.range(of: tag, in: search) {
            var index = found.upperBound
            var value = 0
            var digits = 0
            while index < data.endIndex, data[index] >= 0x30, data[index] <= 0x39 {
                value = value * 10 + Int(data[index] - 0x30)
                index += 1
                digits += 1
            }
            if digits > 0 { seen = max(seen, value) }
            search = index..<data.endIndex
        }
        guard seen > 0 else { return }
        let now = CACurrentMediaTime()
        lock.withLock {
            let newly = seen - current.wheelSeen
            guard newly > 0 else { return }
            current.wheelSeen = seen
            for sent in wheelSent.prefix(newly) { current.rtts.append((now - sent) * 1000) }
            wheelSent.removeFirst(min(newly, wheelSent.count))
        }
    }

    private static func count(of needle: Data, in haystack: Data) -> Int {
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, in: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}

/// One `daemon` channel as the daemon's own Unix socket: the JSON lines
/// cmux-mobile-host's splice would carry, with no link in between.
final class UnixSocketChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    private let fd: Int32
    private let stats: RealDaemonPanStats?
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var closed = false
    private var sendBuffer = Data()

    init(path: String, id: UInt32, stats: RealDaemonPanStats?) throws {
        self.id = id
        self.stats = stats
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinkError(code: "socket", message: "socket: \(errno)") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw LinkError(code: "socket", message: "path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LinkError(code: "socket", message: "connect \(path): \(code)")
        }
        self.fd = fd
        let thread = Thread { [self] in readLoop() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var partial = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            let chunk = Data(buffer[0..<count])
            if let stats {
                partial.append(chunk)
                while let newline = partial.firstIndex(of: 0x0A) {
                    stats.received(Data(partial[partial.startIndex..<newline]))
                    partial.removeSubrange(partial.startIndex...newline)
                }
            }
            let resume: CheckedContinuation<Data?, any Error>? = lock.withLock {
                if let waiter {
                    self.waiter = nil
                    return waiter
                }
                queue.append(chunk)
                return nil
            }
            resume?.resume(returning: chunk)
        }
        Darwin.close(fd)
        let waiter: CheckedContinuation<Data?, any Error>? = lock.withLock {
            closed = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: nil)
    }

    func send(_ data: Data) async throws {
        if let stats {
            let lines: [Data] = lock.withLock {
                sendBuffer.append(data)
                var lines: [Data] = []
                while let newline = sendBuffer.firstIndex(of: 0x0A) {
                    lines.append(Data(sendBuffer[sendBuffer.startIndex..<newline]))
                    sendBuffer.removeSubrange(sendBuffer.startIndex...newline)
                }
                return lines
            }
            for line in lines { stats.sent(line) }
        }
        try writeLock.withLock {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { throw LinkError(code: "closed", message: "write: \(errno)") }
                    offset += written
                }
            }
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Data?? = lock.withLock {
                if !queue.isEmpty { return .some(queue.removeFirst()) }
                if closed { return .some(nil) }
                waiter = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close(code: String, reason: String) async {
        shutdown(fd, SHUT_RDWR)
    }
}

/// Display frames while a finger is on the screen (and 0.6 s after it lifts,
/// for the fling), the main queue's latency (a ping every 10 ms from another
/// thread), and the terminal page's scroll view each frame. Touches are
/// watched by a recognizer on the window that never recognizes and never
/// delays or cancels a touch.
@MainActor
final class RealDaemonPanMeter: NSObject {
    private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var changed: (Int, TimeInterval) -> Void = { _, _ in }
        private var down = 0

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            down += touches.count
            changed(down, CACurrentMediaTime())
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches) }

        private func lifted(_ touches: Set<UITouch>) {
            down = max(0, down - touches.count)
            changed(down, CACurrentMediaTime())
            if down == 0 { state = .failed }
        }

        override func reset() { down = 0 }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    private(set) var touchesDown = 0
    private(set) var touches = 0
    private(set) var lastTouchUp: CFTimeInterval?
    private var intervals: [Double] = []
    private var lastFrame: CFTimeInterval?
    private var period: Double = 1.0 / 60
    private var link: CADisplayLink?
    private let watcher = TouchWatcher(target: nil, action: nil)
    private weak var window: UIWindow?
    private weak var scroll: UIScrollView?
    private var last: (offset: CGFloat, height: CGFloat, translation: CGFloat)?
    private var contentJumps = 0
    private var yanks = 0
    private var driftMax: CGFloat = 0
    private var trackedFrames = 0
    private let pings = PingSampler()

    init(window: UIWindow) {
        self.window = window
        super.init()
        watcher.changed = { [weak self] down, time in
            guard let self else { return }
            if down > touchesDown { touches += down - touchesDown }
            touchesDown = down
            if down == 0 { lastTouchUp = time }
        }
        window.addGestureRecognizer(watcher)
        scroll = Self.terminalScroll(in: window)
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        pings.start()
    }

    /// The tallest scroll view of the terminal page (`TerminalScrollView`).
    private static func terminalScroll(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var stack = [view]
        while let next = stack.popLast() {
            if let scroll = next as? UIScrollView, String(describing: type(of: scroll)).contains("TerminalScrollView") {
                if best == nil || scroll.contentSize.height > best!.contentSize.height { best = scroll }
            }
            stack.append(contentsOf: next.subviews)
        }
        return best
    }

    private var active: Bool {
        touchesDown > 0 || lastTouchUp.map { CACurrentMediaTime() - $0 < 0.6 } ?? false
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { lastFrame = link.timestamp }
        if link.duration > 0 { period = link.duration }
        pings.active = active
        guard active, let lastFrame else {
            last = nil
            return
        }
        intervals.append(link.timestamp - lastFrame)
        guard let scroll else { return }
        let offset = scroll.contentOffset.y
        let height = scroll.contentSize.height
        let translation = scroll.panGestureRecognizer.translation(in: scroll).y
        let screen = max(1, scroll.bounds.height)
        let bottom = height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        if let last {
            if abs(height - last.height) > screen { contentJumps += 1 }
            if touchesDown > 0, abs(bottom - offset) < 2, bottom - last.offset > screen { yanks += 1 }
            if scroll.isTracking, touchesDown > 0 {
                trackedFrames += 1
                // While the finger tracks, the page moves by the finger's own
                // movement; what it moved more (less the document's own growth
                // above, which a prepend compensates) is drift.
                let drift = abs((offset - last.offset) + (translation - last.translation) - (height - last.height))
                let plain = abs((offset - last.offset) + (translation - last.translation))
                driftMax = max(driftMax, min(drift, plain))
            }
        }
        last = (offset, height, translation)
    }

    func stop() {
        link?.invalidate()
        link = nil
        pings.stop()
        window?.removeGestureRecognizer(watcher)
    }

    var summary: String {
        let sorted = intervals.sorted()
        func ms(_ quantile: Double) -> String {
            guard !sorted.isEmpty else { return "-" }
            return String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile))] * 1000)
        }
        let hitches = intervals.filter { $0 > period * 1.5 }.count
        let stalls = intervals.filter { $0 > 0.05 }.count
        let rowHeight: CGFloat = 17
        return "frames=\(intervals.count) p50=\(ms(0.5)) p95=\(ms(0.95)) max=\(ms(1)) hitches=\(hitches) stalls=\(stalls)"
            + " pingMax=\(String(format: "%.1f", pings.max)) periodMs=\(String(format: "%.1f", period * 1000)) touches=\(touches)"
            + " scroll=\(scroll != nil) tracked=\(trackedFrames) contentJumps=\(contentJumps) yanks=\(yanks)"
            + " driftRows=\(String(format: "%.1f", driftMax / rowHeight))"
    }
}

/// The main queue's latency while `active`: a ping from another thread every 10 ms.
private final class PingSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: Double = 0
    private var timer: DispatchSourceTimer?
    private var isActive = false

    var active: Bool {
        get { lock.withLock { isActive } }
        set { lock.withLock { isActive = newValue } }
    }

    var max: Double { lock.withLock { worst } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "real-daemon-pan.ping"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            let sent = CACurrentMediaTime()
            DispatchQueue.main.async {
                let latency = (CACurrentMediaTime() - sent) * 1000
                self.lock.withLock { self.worst = Swift.max(self.worst, latency) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }
}
#endif
