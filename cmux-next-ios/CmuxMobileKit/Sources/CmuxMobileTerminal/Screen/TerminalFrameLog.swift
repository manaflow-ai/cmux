#if os(iOS) && DEBUG
import CmuxMobileDesign
import Foundation
import os
import QuartzCore

/// DEBUG/Demo only (G-04, ACCEPTANCE M-FRAMELOG). Launch with `-CmuxMobileFrameLog`
/// (or `CMUX_MOBILE_FRAMELOG=1`; one `FrameLogSwitch` for this and the feed's
/// `FrameIntervalLog`): the shared `FrameClock` records every frame's interval (actual timestamp minus the
/// previous one) with the page's phase, whether output streamed in the last
/// 100 ms, and the main-thread time the screen spent in the frame. Each
/// gesture (or 5 s of other frames) logs a summary on `dev.cmux.mobile:frames`
/// and appends ndjson lines to `Documents/frame-log.ndjson`, which the rig
/// copies out with `simctl get_app_container`. The terminal's work is also
/// marked with signposts (`output-batch`, `update-document`, `apply-scroll`,
/// `present`) for Instruments.
@MainActor
final class TerminalFrameLog {
    static var isEnabled: Bool { FrameLogSwitch.isEnabled }
    static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "terminal-frames")
    private static let logger = Logger(subsystem: "dev.cmux.mobile", category: "frames")

    private var token: FrameClock.Token?
    private var last: CFTimeInterval = 0
    private var stats: TerminalFrameStats
    private var phase = "following"
    private var lastOutput: CFTimeInterval = 0
    private var workMs = 0.0
    private var windowStart: CFTimeInterval = 0
    private var lines: [String] = []
    private let surfaceName: String

    init(surfaceName: String, frameDuration: Double) {
        self.surfaceName = surfaceName
        stats = TerminalFrameStats(frameDuration: frameDuration)
    }

    func start() {
        guard Self.isEnabled, token == nil else { return }
        token = FrameClock.shared.subscribe { [weak self] in self?.tick($0) }
        last = 0
    }

    func stop() {
        if let token { FrameClock.shared.unsubscribe(token) }
        token = nil
        flush(reason: "stop")
    }

    /// The page's phase, read every frame (interacting, following, reading).
    var phaseProvider: () -> String = { "following" }
    /// The page shows rows the frame on screen does not cover (V6-2/3/4).
    var blankProvider: () -> Bool = { false }

    func outputArrived() { lastOutput = CACurrentMediaTime() }

    /// Main-thread work done for the screen in this frame (`name`: the signpost).
    func work(_ name: String, _ seconds: CFTimeInterval, outermost: Bool = true) {
        if outermost { workMs += seconds * 1000 }
        parts[name, default: 0] += seconds * 1000
    }
    private var parts: [String: Double] = [:]

    private func tick(_ tick: FrameClock.Tick) {
        let now = tick.timestamp
        defer { last = now; workMs = 0; parts.removeAll(keepingCapacity: true) }
        guard last > 0 else { windowStart = now; return }
        let current = phaseProvider()
        if current != phase {
            if phase == "interacting" { flush(reason: "gesture end") }
            phase = current
        }
        let interval = now - last
        let streaming = now - lastOutput < 0.1
        let key = TerminalFrameStats.Key(phase: phase, streaming: streaming)
        stats.add(key, interval: interval, workMs: workMs)
        lines.append(String(format: "{\"t\":%.4f,\"dt_ms\":%.2f,\"target_ms\":%.2f,\"phase\":\"%@\",\"streaming\":%@,\"blank\":%@,\"work_ms\":%.2f,\"parts\":{%@},\"surface\":\"%@\"}",
                            Date().timeIntervalSince1970, interval * 1000, (tick.targetTimestamp - now) * 1000, phase,
                            streaming ? "true" : "false", blankProvider() ? "true" : "false", workMs,
                            parts.map { String(format: "\"%@\":%.3f", $0.key, $0.value) }.joined(separator: ","), surfaceName))
        if phase != "interacting", now - windowStart > 5 { flush(reason: "5 s") }
    }

    private func flush(reason: String) {
        windowStart = last
        let report = stats.report
        if !report.isEmpty {
            for line in report.split(separator: "\n") {
                Self.logger.notice("frames \(self.surfaceName, privacy: .public) (\(reason, privacy: .public)): \(line, privacy: .public)")
            }
        }
        stats = TerminalFrameStats(frameDuration: stats.frameDuration)
        guard !lines.isEmpty else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        lines.removeAll(keepingCapacity: true)
        FrameLogFile.append(data, to: FrameLogFile.url(in: .documentDirectory, "frame-log.ndjson"))
    }
}
#endif
