#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import ImageIO
import UniformTypeIdentifiers

/// DEBUG ONLY. `debug.window_record` {dir, seconds (at most 8), window?}:
/// the window as the window server composited it (`compositedSnapshot`,
/// as `debug.window_snapshot`), once per display frame of its screen (the
/// window's display link, 120 Hz on ProMotion), as JPEG frames
/// `DIR/frame-NNNNN.jpg` plus `DIR/frames.json` (index, host time in
/// seconds since the first frame). Returns at once; the recording stops by
/// itself. For before/after motion proof of the Home tab against
/// MessagesLab's own recordings (its `--live-send`); no Screen Recording
/// permission is needed for an app's own window.
@MainActor
enum DebugWindowRecord {
    private static var running: Recorder?

    static func start(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard running == nil else { return .object(["error": .string("a recording is running")]) }
        guard let window = DebugWindowSnapshot.window(params, services: services) else { return .object(["error": .string("no such window")]) }
        guard let dir = params["dir"]?.stringValue.map({ ($0 as NSString).expandingTildeInPath }) else {
            return .object(["error": .string("dir is required")])
        }
        let seconds = min(8, max(0.1, params["seconds"]?.doubleValue ?? 3))
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            return .object(["error": .string("cannot create \(dir)")])
        }
        let recorder = Recorder(window: window, dir: URL(fileURLWithPath: dir), seconds: seconds) { running = nil }
        running = recorder
        recorder.start()
        return .object(["dir": .string(dir), "seconds": JSONValue(seconds)])
    }

    private final class Recorder: NSObject {
        let window: NSWindow
        let dir: URL
        let seconds: Double
        let done: () -> Void
        private var link: CADisplayLink?
        private var start0: CFTimeInterval?
        private var times: [Double] = []
        private let encoder = DispatchQueue(label: "debug.window_record", qos: .userInitiated)

        init(window: NSWindow, dir: URL, seconds: Double, done: @escaping () -> Void) {
            self.window = window
            self.dir = dir
            self.seconds = seconds
            self.done = done
        }

        func start() {
            let link = window.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            let t0 = start0 ?? now
            start0 = t0
            guard now - t0 <= seconds else { finish(); return }
            guard let image = window.compositedSnapshot() else { return }
            let index = times.count
            times.append(now - t0)
            let url = dir.appendingPathComponent(String(format: "frame-%05d.jpg", index))
            encoder.async {
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }

        private func finish() {
            link?.invalidate()
            link = nil
            let index = dir.appendingPathComponent("frames.json")
            let times = self.times
            encoder.async {
                if let data = try? JSONSerialization.data(withJSONObject: ["times": times]) { try? data.write(to: index) }
            }
            done()
        }
    }
}
#endif
