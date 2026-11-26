import CmuxVNC
import Foundation
import QuartzCore

/// Opt-in per-update and per-input timings, one JSON line each, appended to
/// a file (default Documents/perf.log; pull it with `devicectl device copy from`).
/// Set `ScreenSession.perf` to turn it on:
/// - frame: server latency (request → first byte), receive+decode, pixels,
///   bytes since the last frame, wait on the main queue, image copy, draw;
/// - input: what was sent, and the time until the next frame shows (input → frame).
@MainActor
public final class ScreenPerfLog {
    private let handle: FileHandle?
    private let start = CACurrentMediaTime()
    private var lastBytes = 0
    private var pendingInput: (name: String, at: CFTimeInterval)?

    public init(file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf.log")) {
        let url = file
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        write(["event": "session", "at": Date().ISO8601Format()])
    }

    public func input(_ name: String) {
        if pendingInput == nil { pendingInput = (name, CACurrentMediaTime()) }
        write(["event": "input", "t": ms(CACurrentMediaTime() - start), "name": name])
    }

    public func frame(_ frame: VNCFrame, stats: VNCSessionStats, copyMs: Double, drawMs: Double) {
        let now = CACurrentMediaTime()
        let queued = Double(DispatchTime.now().uptimeNanoseconds &- frame.publishedAt) / 1e6 - copyMs - drawMs
        var line: [String: Any] = [
            "event": "frame", "t": ms(now - start), "seq": frame.sequence,
            "server_ms": stats.lastUpdateLatencyMs ?? -1, "recv_decode_ms": stats.lastDecodeMs ?? -1,
            "pixels": stats.lastUpdatePixels, "bytes": stats.bytesReceived - lastBytes,
            "main_wait_ms": max(0, queued), "copy_ms": copyMs, "draw_ms": drawMs,
        ]
        lastBytes = stats.bytesReceived
        if let input = pendingInput {
            line["input"] = input.name
            line["input_to_frame_ms"] = ms(now - input.at)
            pendingInput = nil
        }
        write(line)
    }

    /// Stream mode: a rendered video frame (WebRTC) — closes an input's
    /// input → frame timing. Frames repeat while idle (refresh), so a
    /// measurement is the first frame after the input, an upper bound.
    public func streamFrame() {
        guard let input = pendingInput else { return }
        pendingInput = nil
        write(["event": "frame", "t": ms(CACurrentMediaTime() - start), "input": input.name,
               "input_to_frame_ms": ms(CACurrentMediaTime() - input.at), "stream": true])
    }

    private func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 1000).rounded() }

    private func write(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        handle?.write(data + Data("\n".utf8))
    }
}
