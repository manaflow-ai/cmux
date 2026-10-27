#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// DEBUG ONLY. `debug.window_record` {dir, seconds (at most 12), window?}:
/// the window as the window server composited it (`compositedImage`,
/// as `debug.window_snapshot`, plus the app's panels over it that are not
/// its children, such as the palette opened with no key window), once per display frame of its screen (a
/// FrameClient of the window's FrameScheduler, 120 Hz on ProMotion), as JPEG frames
/// `DIR/frame-NNNNN.jpg` plus `DIR/frames.json` (index, host time in
/// seconds since the first frame). Returns at once; the recording stops by
/// itself. For before/after motion proof of the Home tab against
/// MessagesLab's own recordings (its `--live-send`); no Screen Recording
/// permission is needed for an app's own window.
///
/// `frames.json` also carries, per frame, how bright it was: `luminance`, its
/// mean Rec. 709 luminance (0...1), and `peak`, the brightest of its 64 cells.
/// A flash test asserts that neither rises over the window at rest
/// (scripts/ci/frame-pacing/dark_load_flash.py).
@MainActor
enum DebugWindowRecord {
    private static var running: Recorder?

    static func start(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard running == nil else { return .object(["error": .string("a recording is running")]) }
        guard let window = DebugWindowSnapshot.window(params, services: services) else { return .object(["error": .string("no such window")]) }
        guard let dir = params["dir"]?.stringValue.map({ ($0 as NSString).expandingTildeInPath }) else {
            return .object(["error": .string("dir is required")])
        }
        let seconds = min(12, max(0.1, params["seconds"]?.doubleValue ?? 3))
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
            return .object(["error": .string("cannot create \(dir)")])
        }
        let recorder = Recorder(window: window, dir: URL(fileURLWithPath: dir), seconds: seconds) { running = nil }
        running = recorder
        recorder.start()
        return .object(["dir": .string(dir), "seconds": .number(seconds)])
    }

    @MainActor
    private final class Recorder {
        let window: NSWindow
        let seconds: Double
        let done: () -> Void
        private var client: FrameClient?
        private var start0: CFTimeInterval?
        /// The frames: captured, measured and written off the main thread.
        private let frames: WindowRecording

        init(window: NSWindow, dir: URL, seconds: Double, done: @escaping () -> Void) {
            self.window = window
            self.seconds = seconds
            self.done = done
            frames = WindowRecording(dir: dir)
        }

        func start() {
            let client = FrameClient(owner: "debug.window_record", isAnimation: false, on: .forWindow(window)) { [weak self] tick in
                self?.tick(tick) ?? false
            }
            self.client = client
            client.activate()
        }

        /// One frame; false once the recording is over. Main reads only the window numbers and the frame:
        /// the capture waits for the window server, so it runs on the recording's queue.
        private func tick(_ tick: FrameTick) -> Bool {
            let now = tick.timestamp
            let t0 = start0 ?? now
            start0 = t0
            guard now - t0 <= seconds else { finish(); return false }
            if let plan = window.compositedCapturePlan(adding: overlayPanels()) { frames.record(plan, at: now - t0) }
            return true
        }

        /// The app's visible panels over the window that are not its children
        /// (the palette opened with no key window, hover cards), so the
        /// recording shows them as a person sees them.
        private func overlayPanels() -> [NSWindow] {
            NSApplication.shared.windows.filter { other in
                other !== window && other is NSPanel && other.isVisible && other.windowNumber > 0
                    && other.alphaValue > 0 && other.frame.intersects(window.frame)
            }
        }

        /// The client goes idle when `tick` returns false.
        private func finish() {
            frames.finish()
            done()
        }
    }
}
#endif
