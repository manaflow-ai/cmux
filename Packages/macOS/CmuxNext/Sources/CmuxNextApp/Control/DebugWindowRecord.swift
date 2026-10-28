#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// DEBUG ONLY. `debug.window_record` {dir, seconds (at most 12), window?}, and
/// `--record-launch` (``watchLaunch``) for the launch, before the control socket is up:
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
    /// The recordings `--record-launch` is making; each drops out when it ends.
    private static var launchRecorders: [Recorder] = []
    /// Every window `--record-launch` has started on, so each is recorded once.
    private static var launchSeen: Set<ObjectIdentifier> = []

    /// What `--record-launch DIR [--record-launch-seconds S]` asks for: every
    /// window recorded from the moment it is made, for S seconds (6 by default,
    /// at most 12), into `DIR/window-N`. nil without the argument or its folder.
    struct LaunchRequest: Equatable {
        let dir: String
        let seconds: Double

        init?(arguments: [String]) {
            guard let flag = arguments.firstIndex(of: "--record-launch"), flag + 1 < arguments.count,
                  !arguments[flag + 1].hasPrefix("--") else { return nil }
            dir = (arguments[flag + 1] as NSString).expandingTildeInPath
            let asked = arguments.firstIndex(of: "--record-launch-seconds").flatMap { index in
                index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
            }
            seconds = min(12, max(0.1, asked ?? 6))
        }
    }

    private static let launchRequest = LaunchRequest(arguments: ProcessInfo.processInfo.arguments)
    /// Looks for new windows once a display frame while the launch is recorded.
    private static var launchWatch: FrameClient?

    /// With `--record-launch`, records every main window the launch makes
    /// (`ShellWindow`), each from its first composited frame: once a display
    /// frame of the app's clock, a window not seen yet starts its own
    /// recording at once. Each frame also carries its time since the process
    /// started (`processMs`), the launch marks' clock. Looks for 30 s.
    /// Runs from `DebugTimings.install`, before the first window is made.
    static func watchLaunch() {
        guard let request = launchRequest, launchWatch == nil else { return }
        let watch = FrameClient(owner: "debug.record_launch", isAnimation: false, on: .app) { _ in
            for window in NSApplication.shared.windows where window is ShellWindow
                && launchSeen.insert(ObjectIdentifier(window)).inserted {
                let dir = URL(fileURLWithPath: request.dir).appendingPathComponent("window-\(launchSeen.count)")
                guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
                let id = ObjectIdentifier(window)
                let recorder = Recorder(window: window, dir: dir, seconds: request.seconds, sinceLaunch: true) {
                    launchRecorders.removeAll { ObjectIdentifier($0.window) == id }
                }
                launchRecorders.append(recorder)
                recorder.start()
            }
            return DebugTimings.millisecondsSinceProcessStart() < 30_000
        }
        launchWatch = watch
        watch.activate()
    }

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
        /// Whether each frame also records its time since the process started.
        let sinceLaunch: Bool
        private var client: FrameClient?
        private var start0: CFTimeInterval?
        /// The frames: captured, measured and written off the main thread.
        private let frames: WindowRecording
        /// The time of the last frame queued (a display link's first frame can report the frame taken at start).
        private var lastTime: Double?
        private var finished = false
        /// A launch recording ends with its window: the launch closes its
        /// window once the restored windows take every workspace.
        private var closeObservation: MainActorObservation?

        init(window: NSWindow, dir: URL, seconds: Double, sinceLaunch: Bool = false, done: @escaping () -> Void) {
            self.window = window
            self.seconds = seconds
            self.sinceLaunch = sinceLaunch
            self.done = done
            frames = WindowRecording(dir: dir)
        }

        func start() {
            let client = FrameClient(owner: "debug.window_record", isAnimation: false, on: .forWindow(window)) { [weak self] tick in
                self?.tick(at: tick.timestamp) ?? false
            }
            self.client = client
            client.activate()
            guard sinceLaunch else { return }
            // raw-observer-allow: one window's close, DEBUG launch recording only (no AppServices exists yet)
            closeObservation = MainActorObservation(NSWindow.willCloseNotification, object: window) { [weak self] in self?.finish() }
            // Found on the app's frame: this frame of the window may be its first.
            _ = tick(at: CACurrentMediaTime())
        }

        /// One frame; false once the recording is over. Main reads only the window numbers and the frame:
        /// the capture waits for the window server, so it runs on the recording's queue.
        private func tick(at now: CFTimeInterval) -> Bool {
            if sinceLaunch, start0 == nil {
                // A launch recording starts at the window's first composited frame: a restored
                // window waits off screen for its content. One that never shows stops after 30 s.
                guard DebugTimings.millisecondsSinceProcessStart() < 30_000 else { finish(); return false }
                guard window.isVisible else { return true }
            }
            let t0 = start0 ?? now
            // A plain recording's clock runs from its first tick, so it ends even if no frame is captured.
            if !sinceLaunch { start0 = t0 }
            guard now - t0 <= seconds else { finish(); return false }
            // The window's first link frame can report the frame taken at start.
            if let lastTime, now - t0 <= lastTime { return true }
            guard let plan = window.compositedCapturePlan(adding: overlayPanels()) else { return true }
            // A launch recording's time zero is its first captured frame (its 30 s limit above ends it if none comes).
            start0 = t0
            lastTime = now - t0
            frames.record(plan, at: now - t0, processMs: sinceLaunch ? DebugTimings.millisecondsSinceProcessStart() : nil)
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
            guard !finished else { return }
            finished = true
            closeObservation = nil
            frames.finish()
            done()
        }
    }
}
#endif
