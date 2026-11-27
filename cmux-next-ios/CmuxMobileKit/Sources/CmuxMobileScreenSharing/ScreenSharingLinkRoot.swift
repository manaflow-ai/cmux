// DEBUG builds only: no pairing-link viewer or latency probe ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxMobileBrowserStream
import CmuxScreenKit
import CmuxScreenKitUI
import Foundation
import QuartzCore
public import SwiftUI

/// `CMUX_MOBILE_SS_LINK=cmux-vnc://pair...`: the Screen Sharing viewer (the same `ScreenSessionView`
/// and `ScreenVideoView` the device hub path opens) straight on a `cmux-vnc-host --capture`
/// pairing link, with no sign-in or device hub.
///
/// With `CMUX_MOBILE_SS_MARKER=CELL_FRACTION,ORIGIN_Y` it also measures the glass-to-glass marker
/// the way `RdMarkerClickLatencyTests` does on the Mac, but to the presented frame
/// (scripts/measure/screen-stream-eval/targets/iphone-sim.sh): `CMUX_MOBILE_SS_INPUT` `key` (an
/// "a" press) or `click` (on the marker's click pad), `CMUX_MOBILE_SS_SAMPLES` inputs (default
/// 200), each timed from the session's send to the first decoded frame and the first present that
/// show the next counter (1 s = lost), then a 40 to 160 ms gap. What "presented" means depends on
/// the renderer `ScreenVideoView` has; `present_clock` names both. It writes one line,
/// `iphonesim: {...}`, to stdout and Documents/iphonesim.json.
public struct ScreenSharingLinkRoot: View {
    @State private var session: ScreenSession?

    public init() {}

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    public static var isRequested: Bool { environment["CMUX_MOBILE_SS_LINK"] != nil }

    public var body: some View {
        Group {
            if let session {
                ScreenSessionView(session: session, features: ScreenSharingViewerScreen.features) {}
            } else {
                Text(verbatim: "CMUX_MOBILE_SS_LINK is not a cmux-vnc://pair link")
            }
        }
        .task { await start() }
    }

    @MainActor
    private func start() async {
        guard session == nil, let link = Self.environment["CMUX_MOBILE_SS_LINK"].flatMap(URL.init(string:)),
              let pairing = VNCPairing(link: link) else { return }
        let probe = Self.probe(Self.environment["CMUX_MOBILE_SS_MARKER"])
        let session = ScreenSession(title: pairing.name, pairing: pairing)
        session.vncRules = ScreenSharingVNCRules.rules
        // Before the viewer exists: the probe watches its video view from when it is made.
        session.debugVideoProbe = probe
        self.session = session
        let connectStart = CACurrentMediaTime()
        session.connect()
        guard let probe else { return }
        let input = Self.environment["CMUX_MOBILE_SS_INPUT"] ?? "click"
        let samples = Int(Self.environment["CMUX_MOBILE_SS_SAMPLES"] ?? "") ?? 200
        let report = await LatencyRun(webRTC: session, probe: probe, input: input, samples: samples,
                                      connectStart: connectStart).run()
        Self.write(report)
    }

    /// The `cmux.rd/1` viewer (`MacScreenRdView`, a hub device's Mac or Linux share host): with
    /// `CMUX_MOBILE_SS_MARKER` set, the first rd model this process opens runs the same latency
    /// run and writes the same `iphonesim:` line, timed at the `BrowserVideoDecoder`'s enqueue to
    /// its `DisplayImmediately` layer. Called before the model connects.
    static func measureRd(_ model: StreamedBrowserModel) {
        guard !rdMeasured, let probe = probe(environment["CMUX_MOBILE_SS_MARKER"]) else { return }
        rdMeasured = true
        model.decoder.debugEnqueued = { probe.enqueued($0) }
        let input = environment["CMUX_MOBILE_SS_INPUT"] ?? "click"
        let samples = Int(environment["CMUX_MOBILE_SS_SAMPLES"] ?? "") ?? 200
        let connectStart = CACurrentMediaTime()
        Task { @MainActor in
            write(await LatencyRun(rd: model, probe: probe, input: input, samples: samples, connectStart: connectStart).run())
        }
    }

    @MainActor private static var rdMeasured = false

    /// `CELL_FRACTION,ORIGIN_Y`.
    static func probe(_ marker: String?) -> ScreenPresentProbe? {
        guard let values = marker?.split(separator: ",").compactMap({ Double($0) }), values.count == 2 else { return nil }
        return ScreenPresentProbe(cellFraction: values[0], originY: values[1])
    }

    private static func write(_ report: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("iphonesim: ".utf8) + json + Data("\n".utf8))
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? json.write(to: documents.appendingPathComponent("iphonesim.json"))
        }
    }
}

/// One latency run on a connected stream (see `ScreenSharingLinkRoot`): the WebRTC session or
/// the `cmux.rd/1` model, each with its own input and stats.
@MainActor
private struct LatencyRun {
    let probe: ScreenPresentProbe
    let input: String
    let samples: Int
    let connectStart: CFTimeInterval
    let engine: @MainActor () -> String
    /// Points the click at the marker's click pad, `pad` in 0...1 of the frame.
    let aim: @MainActor (_ pad: CGPoint) async -> Void
    let send: @MainActor () -> Void
    /// Called before the first input; its closure, after the last, adds the stream's stats.
    let stats: @MainActor () async -> @MainActor (_ seconds: Double) async -> [String: Any]

    init(webRTC session: ScreenSession, probe: ScreenPresentProbe, input: String, samples: Int,
         connectStart: CFTimeInterval) {
        self.probe = probe
        self.input = input
        self.samples = samples
        self.connectStart = connectStart
        engine = { "webrtc (cmux-next-ios ScreenSessionView, ScreenVideoView/\(probe.rendererName ?? "unknown renderer")) in the iOS Simulator" }
        aim = { pad in
            // The viewer lays out the frame size from the video's (bounded: 5 s).
            for _ in 0 ..< 50 where session.frameSize.width <= 0 { try? await Task.sleep(for: .milliseconds(100)) }
            let frame = session.frameSize
            session.movePointer(to: CGPoint(x: pad.x * frame.width, y: pad.y * frame.height))
        }
        send = input == "key" ? { session.tap(VNCKeysym(character: "a")) } : { session.click() }
        stats = {
            let before = await session.stream?.videoStats()
            return { seconds in
                var report: [String: Any] = [:]
                guard let before, let after = await session.stream?.videoStats(), seconds > 0 else { return report }
                report["frames_per_s"] = (after.framesDecoded - before.framesDecoded) / seconds
                report["mbit_per_s"] = (after.bytesReceived - before.bytesReceived) * 8 / seconds / 1e6
                report["decode_ms_mean"] = after.framesDecoded > before.framesDecoded
                    ? (after.totalDecodeTime - before.totalDecodeTime) / (after.framesDecoded - before.framesDecoded) * 1000 : -1
                report["rtt_ms"] = after.rttMs ?? -1
                report["jitter_buffer_ms"] = after.jitterBufferMs ?? -1
                report["codec"] = after.codec ?? "?"
                report["decoder"] = after.decoder ?? "?"
                report["packets_lost"] = after.packetsLost - before.packetsLost
                report["frames_dropped"] = after.framesDropped - before.framesDropped
                return report
            }
        }
    }

    init(rd model: StreamedBrowserModel, probe: ScreenPresentProbe, input: String, samples: Int,
         connectStart: CFTimeInterval) {
        self.probe = probe
        self.input = input
        self.samples = samples
        self.connectStart = connectStart
        engine = { "cmux.rd/1 (cmux-next-ios MacScreenRdView, BrowserVideoDecoder/AVSampleBufferDisplayLayer) in the iOS Simulator" }
        let pad = Box()
        aim = { pad.point = $0 }
        send = input == "key" ? { model.debugPress("KeyA", key: "a", text: "a") } : {
            model.touch("down", at: pad.point)
            model.touch("up", at: pad.point)
        }
        stats = {
            let frames = model.meter.frames
            return { seconds in
                let meter = model.meter
                var report: [String: Any] = [
                    "frames_per_s": seconds > 0 ? Double(meter.frames - min(frames, meter.frames)) / seconds : -1,
                    "mbit_per_s": Double(meter.kbps) / 1000,
                    "decode_ms_mean": meter.decodeMillis,
                    "carrier": meter.carrier,
                    "decoder": "VideoToolbox",
                ]
                if let latency = meter.latencyMillis { report["host_to_decoded_ms_p50"] = latency }
                return report
            }
        }
    }

    @MainActor private final class Box { var point = CGPoint.zero }

    func run() async -> [String: Any] {
        // The first decoded marker (bounded: 30 s, the simulator's first connect included).
        for _ in 0 ..< 300 where probe.value == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard probe.value != nil else {
            return ["error": "no marker in the video within 30 s", "present_clock": probe.presentClock]
        }
        let firstMarkerMs = (CACurrentMediaTime() - connectStart) * 1000
        let size = probe.frameSize
        if input == "click" {
            // The marker's click pad (cells 20 to 23, never read).
            await aim(CGPoint(x: 22 * probe.cellFraction,
                              y: probe.originY + 0.5 * probe.cellFraction * size.width / max(size.height, 1)))
        }
        let finish = await stats()
        let started = CACurrentMediaTime()
        var decoded: [Double] = [], presented: [Double] = [], gap: [Double] = []
        var lost = 0, decodedNotPresented = 0
        while presented.count + lost < samples {
            guard let current = probe.value else { break }
            probe.reset()
            let sent = CACurrentMediaTime()
            send()
            let timeout = Task { @MainActor [probe] () -> Bool in
                // The rd bench's loss deadline; a cancelled timer must not end the next wait.
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return false }
                // True when the awaited value was decoded but never presented.
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
                // A lost input can still show late. Wait until the counter holds still, so its
                // late frame cannot answer the next sample's `current + 1` at once.
                await settle()
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 40 ... 160))) // the rd bench's gap
        }
        let seconds = CACurrentMediaTime() - started
        var report: [String: Any] = [
            "engine": engine(),
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
        report.merge(await finish(seconds)) { _, new in new }
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
#endif
