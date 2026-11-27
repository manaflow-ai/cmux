// DEBUG builds only: no eval viewer or latency probe ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileTransport
import CmuxEgress
import CoreVideo
import Foundation
import Network
import QuartzCore
public import SwiftUI

/// `CMUX_MOBILE_RD_LINK=http://HOST:PORT/?team=T&device=D&mac=M&token=user:U&input=127.0.0.1:P&key=K`:
/// the Mac's screen (`d~0`) as `cmux.rd/1` over a WireGuard cmux link, on the same
/// `StreamedBrowserModel` and `StreamedViewOnlySurface` the Mac Screen over Link viewer uses, dialed
/// with no sign-in to a standalone cmux-mobile-host (scripts/measure/screen-stream-eval/targets/iphone-link.sh:
/// the fake backend at HOST:PORT, the host's `surface` service streamed by `cmux-rd surface-source`).
///
/// With `CMUX_MOBILE_SS_MARKER=CELL_FRACTION,ORIGIN_Y` it measures the glass-to-glass marker as
/// `ScreenSharingLinkRoot` does over WebRTC, with the same keys in its `iphonesim: {...}` line and
/// Documents/iphonesim.json, so the eval compares the two. The input (`CMUX_MOBILE_SS_INPUT` `key`
/// or `click` on the marker's click pad) goes to the source as a datagram on `input` (`K key`,
/// `K click X Y`, fractions of the frame), which the source injects on the Mac: a view-only rd/1
/// session carries no input, and the timer starts at that send, as the WebRTC run's starts at its
/// data-channel send. "Decoded" is when VideoToolbox handed the picture to the layer
/// (`BrowserVideoDecoder.debugPicture`, after the enqueue); "presented" is the `targetTimestamp`
/// of the first `CADisplayLink` tick after it, the same clock the WebRTC run's sample-buffer
/// renderer reports.
public struct ScreenSharingRdLinkRoot: View {
    @State private var run: RdLinkRun?

    public init() {}

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    public static var isRequested: Bool { environment["CMUX_MOBILE_RD_LINK"] != nil }

    public var body: some View {
        Group {
            if let run {
                StreamedViewOnlySurface(model: run.model, label: "Mac screen", identifier: "macScreen.stream")
                    .ignoresSafeArea()
                    .background(Color.black.ignoresSafeArea())
                    .onAppear {
                        run.model.setVisible(true)
                        run.model.reconnect()
                    }
            } else {
                Text(verbatim: "CMUX_MOBILE_RD_LINK is not http://HOST:PORT/?team=&device=&mac=&token=")
            }
        }
        .task { await start() }
    }

    @MainActor
    private func start() async {
        guard run == nil, let raw = Self.environment["CMUX_MOBILE_RD_LINK"],
              let target = RdLinkTarget(raw) else { return }
        let marker = Self.environment["CMUX_MOBILE_SS_MARKER"]?.split(separator: ",").compactMap { Double($0) }
        let probe = marker.flatMap { $0.count == 2 ? RdMarkerProbe(cellFraction: $0[0], originY: $0[1]) : nil }
        let connectStart = CACurrentMediaTime()
        let link: any MacLink
        do {
            link = try await FFIMacLinkDialer(buildSpace: .success(nil)).dial(
                LinkEndpoint(baseURL: target.baseURL, teamID: target.team, deviceID: target.device, macDeviceID: target.mac),
                transport: .wireGuard, accessToken: target.token)
        } catch {
            Self.write(["error": "dial failed: \(error)"])
            return
        }
        guard let opener = link as? any BrowserStreamOpening else {
            Self.write(["error": "the link opens no surface"])
            return
        }
        let model = StreamedBrowserModel(tab: "d~0", url: nil) { sink in
            try await opener.openSurface(tab: "d~0", sink: sink)
        }
        if let probe {
            model.decoder.debugPicture = { pixels in probe.decoded(pixels) }
        }
        let run = RdLinkRun(model: model, link: link)
        self.run = run
        guard let probe else { return }
        let input = Self.environment["CMUX_MOBILE_SS_INPUT"] ?? "click"
        let samples = Int(Self.environment["CMUX_MOBILE_SS_SAMPLES"] ?? "") ?? 200
        let sender = RdInputSender(target: target)
        let report = await RdLatencyRun(model: model, probe: probe, sender: sender, input: input, samples: samples,
                                        connectStart: connectStart).run()
        Self.write(report)
    }

    private static func write(_ report: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("iphonesim: ".utf8) + json + Data("\n".utf8))
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? json.write(to: documents.appendingPathComponent("iphonesim.json"))
        }
    }
}

/// The stream and the link it rides (kept alive for the run).
@MainActor
private final class RdLinkRun {
    let model: StreamedBrowserModel
    let link: any MacLink

    init(model: StreamedBrowserModel, link: any MacLink) {
        self.model = model
        self.link = link
    }
}

/// `CMUX_MOBILE_RD_LINK` parsed.
private struct RdLinkTarget {
    let baseURL: URL
    let team: String
    let device: String
    let mac: String
    let token: String
    let inputHost: String?
    let inputPort: UInt16?
    let inputKey: String?

    init?(_ raw: String) {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme, let host = parts.host else { return nil }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value }
        guard let team = query["team"], let mac = query["mac"], let token = query["token"],
              let base = URL(string: "\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")") else { return nil }
        baseURL = base
        self.team = team
        self.mac = mac
        self.token = token
        device = query["device"] ?? "eval-iphone"
        let input = query["input"]?.split(separator: ":")
        inputHost = input.flatMap { $0.count == 2 ? String($0[0]) : nil }
        inputPort = input.flatMap { $0.count == 2 ? UInt16($0[1]) : nil }
        inputKey = query["key"]
    }
}

/// The eval's input datagrams to the source (`cmux-rd surface-source`, CMUX_RD_SURFACE_EVAL_INPUT).
private final class RdInputSender: @unchecked Sendable {
    private let connection: NWConnection?
    private let key: String

    init(target: RdLinkTarget) {
        key = target.inputKey ?? ""
        if let host = target.inputHost, let port = target.inputPort.flatMap(NWEndpoint.Port.init(rawValue:)) {
            let connection = CmuxEgress.connection(host: NWEndpoint.Host(host), port: port, using: .udp,
                                                   site: "CmuxMobileScreenSharing.ScreenSharingRdLinkRoot")
            connection.start(queue: DispatchQueue(label: "dev.cmux.mobile.rd-eval-input", qos: .userInteractive))
            self.connection = connection
        } else {
            connection = nil
        }
    }

    var available: Bool { connection != nil && !key.isEmpty }

    func send(_ text: String) {
        connection?.send(content: Data("\(key) \(text)".utf8), completion: .contentProcessed { _ in })
    }

    deinit { connection?.cancel() }
}

/// One latency run (see `ScreenSharingRdLinkRoot`): `ScreenSharingLinkRoot`'s `LatencyRun` on the
/// rd/1 stream.
@MainActor
private struct RdLatencyRun {
    let model: StreamedBrowserModel
    let probe: RdMarkerProbe
    let sender: RdInputSender
    let input: String
    let samples: Int
    let connectStart: CFTimeInterval

    func run() async -> [String: Any] {
        guard sender.available else { return ["error": "CMUX_MOBILE_RD_LINK has no input=HOST:PORT and key="] }
        // The first decoded marker (bounded: 30 s, the simulator's first connect included).
        for _ in 0 ..< 300 where probe.value == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard probe.value != nil else {
            return ["error": "no marker in the video within 30 s", "present_clock": probe.presentClock]
        }
        let firstMarkerMs = (CACurrentMediaTime() - connectStart) * 1000
        let size = probe.frameSize
        // The marker's click pad (cells 20 to 23, never read), as fractions of the frame.
        let x = 22 * probe.cellFraction
        let y = probe.originY + 0.5 * probe.cellFraction * size.width / max(size.height, 1)
        let framesBefore = probe.frames
        let streamBefore = model.meter.frames
        let started = CACurrentMediaTime()
        var decoded: [Double] = [], presented: [Double] = [], gap: [Double] = []
        var lost = 0, decodedNotPresented = 0
        while presented.count + lost < samples {
            guard let current = probe.value else { break }
            probe.reset()
            let sent = CACurrentMediaTime()
            sender.send(input == "key" ? "key" : "click \(x) \(y)")
            let timeout = Task { @MainActor [probe] () -> Bool in
                // The rd bench's loss deadline; a cancelled timer must not end the next wait.
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return false }
                return probe.cancelWait() != nil
            }
            let shown = await probe.firstShown(current &+ 1)
            if shown == nil, await timeout.value { decodedNotPresented += 1 }
            timeout.cancel()
            if let shown, let at = shown.presented {
                presented.append((at - sent) * 1000)
                if let decodedAt = shown.decoded {
                    decoded.append((decodedAt - sent) * 1000)
                    gap.append((at - decodedAt) * 1000)
                }
            } else {
                lost += 1
                await settle()
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 40 ... 160))) // the rd bench's gap
        }
        let seconds = CACurrentMediaTime() - started
        var report: [String: Any] = [
            "engine": "rd/1 over the cmux link, WireGuard (cmux-next-ios StreamedBrowserModel, StreamedViewOnlySurface/AVSampleBufferDisplayLayer) in the iOS Simulator",
            "input": input,
            "g2g_ms": Self.percentiles(presented),
            "decoded_g2g_ms": Self.percentiles(decoded),
            "decode_to_present_ms": Self.percentiles(gap),
            "lost": lost,
            "decoded_not_presented": decodedNotPresented,
            "present_clock": probe.presentClock,
            "connect_to_first_marker_ms": firstMarkerMs,
            "frame": ["width": size.width, "height": size.height],
        ]
        if seconds > 0 {
            report["frames_per_s"] = Double(probe.frames - framesBefore) / seconds
            report["stream_frames"] = model.meter.frames &- streamBefore
            report["kbps"] = model.meter.kbps
            report["carrier"] = model.meter.carrier
            report["decode_ms_mean"] = model.meter.decodeMillis
        }
        return report
    }

    /// Returns once the marker's counter has not changed for 300 ms (bounded: 3 s).
    private func settle() async {
        var last = probe.value
        var stableSince = CACurrentMediaTime()
        let deadline = stableSince + 3
        while CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let now = CACurrentMediaTime()
            if probe.value != last {
                last = probe.value
                stableSince = now
            } else if now - stableSince >= 0.3 {
                return
            }
        }
    }

    private static func percentiles(_ values: [Double]) -> [String: Double] {
        let s = values.sorted()
        guard let first = s.first, let last = s.last else { return [:] }
        func q(_ p: Double) -> Double { s[Int((p * Double(s.count - 1)).rounded())] }
        return ["n": Double(s.count), "min": first, "p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": last]
    }
}

/// The glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`: 20 cells, counter
/// LSB first, then guards 1,0,1,0) in each picture the decoder handed to its
/// `AVSampleBufferDisplayLayer` (NV12: plane 0 is luma), and the first `CADisplayLink` tick after
/// it: `ScreenPresentProbe`'s sample-buffer path, without WebRTC.
// crash-allow: the geometry is immutable, and every mutable field is read and written only under `lock`.
private final class RdMarkerProbe: NSObject, @unchecked Sendable {
    struct Shown: Sendable {
        var decoded: CFTimeInterval?
        var presented: CFTimeInterval?
    }

    let cellFraction: Double
    let originY: Double
    private let lock = NSLock()
    private var current: UInt16?
    private var size = CGSize.zero
    private var decodedAt: [UInt16: CFTimeInterval] = [:]
    private var presentedAt: [UInt16: CFTimeInterval] = [:]
    private var waiter: (value: UInt16, resume: CheckedContinuation<Shown?, Never>)?
    private var handed: [(value: UInt16, at: CFTimeInterval)] = []
    private var displayLinkStarted = false
    private var ticks = 0
    private var tickInterval: (min: CFTimeInterval, max: CFTimeInterval)?
    private var pictures = 0

    init(cellFraction: Double, originY: Double) {
        self.cellFraction = cellFraction
        self.originY = originY
    }

    var value: UInt16? { lock.withLock { current } }
    var frameSize: CGSize { lock.withLock { size } }
    var frames: Int { lock.withLock { pictures } }

    var presentClock: [String: Any] {
        lock.withLock { () -> [String: Any] in
            [
                "renderer": "AVSampleBufferDisplayLayer",
                "presented": "targetTimestamp of the first CADisplayLink tick after BrowserVideoDecoder enqueued the frame with DisplayImmediately (the scheduled scan-out, not measured)",
                "hook_problem": NSNull(),
                "display_link_ticks": ticks,
                "tick_ms_min": tickInterval.map { $0.min * 1000 as Any } ?? NSNull(),
                "tick_ms_max": tickInterval.map { $0.max * 1000 as Any } ?? NSNull(),
            ]
        }
    }

    /// A picture the decoder just enqueued (its decode queue).
    func decoded(_ pixels: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let start = lock.withLock { () -> Bool in
            pictures += 1
            defer { displayLinkStarted = true }
            return !displayLinkStarted
        }
        if start { RdDisplayTick.start(for: self) }
        guard let value = Self.marker(in: pixels, cellFraction: cellFraction, originY: originY) else { return }
        lock.withLock {
            size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            current = value
            if decodedAt[value] == nil { decodedAt[value] = now }
            handed.append((value, now))
            if handed.count > 128 { handed.removeFirst() }
        }
    }

    fileprivate func ticked(timestamp: CFTimeInterval, target: CFTimeInterval, callbackAt: CFTimeInterval) {
        let resumes = lock.withLock { () -> [(CheckedContinuation<Shown?, Never>, Shown)] in
            ticks += 1
            let interval = target - timestamp
            if interval > 0 {
                tickInterval = (min(tickInterval?.min ?? interval, interval), max(tickInterval?.max ?? interval, interval))
            }
            let due = handed.prefix { $0.at <= callbackAt }
            handed.removeFirst(due.count)
            return due.compactMap { credit($0.value, presentedAt: target) }
        }
        for resume in resumes { resume.0.resume(returning: resume.1) }
    }

    /// Under `lock`.
    private func credit(_ value: UInt16, presentedAt at: CFTimeInterval) -> (CheckedContinuation<Shown?, Never>, Shown)? {
        if presentedAt[value] == nil { presentedAt[value] = at }
        guard let waiter, Self.reached(value, waiter.value) else { return nil }
        self.waiter = nil
        return (waiter.resume, Shown(decoded: firstDecoded(atOrPast: waiter.value), presented: at))
    }

    func firstShown(_ value: UInt16) async -> Shown? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Shown?, Never>) in
            let done = lock.withLock { () -> Shown? in
                if let presented = presentedAt.filter({ Self.reached($0.key, value) }).map(\.value).min() {
                    return Shown(decoded: firstDecoded(atOrPast: value), presented: presented)
                }
                waiter = (value, continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func cancelWait() -> CFTimeInterval? {
        let (resume, decoded) = lock.withLock { () -> (CheckedContinuation<Shown?, Never>?, CFTimeInterval?) in
            defer { waiter = nil }
            return (waiter?.resume, waiter.flatMap { firstDecoded(atOrPast: $0.value) })
        }
        resume?.resume(returning: nil)
        return decoded
    }

    func reset() {
        lock.withLock {
            decodedAt.removeAll()
            presentedAt.removeAll()
        }
    }

    private func firstDecoded(atOrPast value: UInt16) -> CFTimeInterval? {
        decodedAt.filter { Self.reached($0.key, value) }.map(\.value).min()
    }

    private static func reached(_ value: UInt16, _ target: UInt16) -> Bool {
        value &- target < 0x8000
    }

    private static func marker(in pixels: CVPixelBuffer, cellFraction: Double, originY: Double) -> UInt16? {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let cell = cellFraction * Double(width)
        let y = Int(originY * Double(height) + cell / 2)
        guard cell > 0, y >= 0, y < height, Int(19.5 * cell) < width else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixels)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixels, 0) : CVPixelBufferGetBaseAddress(pixels) else {
            return nil
        }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) : CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var bits = [Bool](repeating: false, count: 20)
        for i in 0 ..< 20 {
            bits[i] = bytes[y * stride + Int((Double(i) + 0.5) * cell)] > 125
        }
        guard Array(bits[16...]) == [true, false, true, false] else { return nil }
        return bits[..<16].enumerated().reduce(0) { $0 | (($1.element ? 1 : 0) << UInt16($1.offset)) }
    }
}

/// The probe's display link on a thread of its own (`ScreenPresentProbe`'s `DisplayTick`).
private final class RdDisplayTick: NSObject {
    private weak var probe: RdMarkerProbe?

    private init(probe: RdMarkerProbe?) {
        self.probe = probe
    }

    static func start(for probe: RdMarkerProbe) {
        let thread = Thread { [weak probe] in
            let tick = RdDisplayTick(probe: probe)
            let link = CADisplayLink(target: tick, selector: #selector(RdDisplayTick.tick(_:)))
            link.add(to: .current, forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "RdMarkerProbe.displayLink"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    @objc func tick(_ link: CADisplayLink) {
        let callbackAt = CACurrentMediaTime()
        guard let probe else {
            link.invalidate()
            return
        }
        probe.ticked(timestamp: link.timestamp, target: link.targetTimestamp, callbackAt: callbackAt)
    }
}
#endif
