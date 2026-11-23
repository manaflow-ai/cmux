import AppKit
import CCmuxLaunchImageFFI
import CmuxNextControl
import CmuxNextDesign
import CmuxNextWakeups

/// Saves each window's last frame for the next launch's stage 0 (`LaunchShell`): a capture of the
/// window, published into the launch image store (cmux-launch-image) and keyed in the launch record
/// by build, window and generation; the record carries the scale, screen layout and appearance the
/// plan checks, so a mismatch shows the plain shell (stub-decision.md 4). When a window is due, how
/// the quit captures it and which captures are stale are the Rust schedule's
/// (`cmux_launch_image_schedule_*`); naming, the atomic 0600 write, the size and count caps and the
/// pruning are the store's (stub-decision.md 8). This type only reads the window state AppKit owns,
/// runs the capture call and hands the bytes over. Incognito windows are never captured.
@MainActor
final class WindowLaunchImages {
    private weak var manager: WindowManager?
    private let work: BackgroundWork
    private let record: AppLaunchRecord
    /// `<support>/launch-images`, nil with no bundle id (as the launch record). Lives as long as the app.
    private struct Published: Sendable { let generation: UInt64; let pixelWidth: UInt32; let pixelHeight: UInt32 }
    private let directory: URL?
    private let build: String
    private var schedules: [String: OpaquePointer] = [:]
    private let timer = DemandTimer(owner: "WindowLaunchImages")
    private var observers: [NSObjectProtocol] = []

    /// The system's appearance, as stage 0 reads it before the app sets its own (`LaunchShell.prepare`).
    static var systemIsDark: Bool {
        if NSApp.appearance == nil { return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    init(manager: WindowManager?, work: BackgroundWork, record: AppLaunchRecord, bundleID: String?) {
        self.manager = manager
        self.work = work
        self.record = record
        build = LaunchShellPaths.build(info: Bundle.main.infoDictionary ?? [:])
        directory = bundleID.map { LaunchShellPaths.images(in: LaunchTimesFile.supportDirectory(bundleID: $0)) }
        guard directory != nil else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowsChanged() }
            })
        }
        for (name, event) in [(NSWindow.willStartLiveResizeNotification, UInt32(4)), (NSWindow.didEndLiveResizeNotification, 5),
                              (NSWindow.willEnterFullScreenNotification, 4), (NSWindow.didEnterFullScreenNotification, 5),
                              (NSWindow.willExitFullScreenNotification, 4), (NSWindow.didExitFullScreenNotification, 5)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.transition(window, event: event) }
            })
        }
    }

    private static var nowMs: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    /// The windows the store keeps: open, not incognito.
    private var windows: [(id: String, window: NSWindow)] {
        guard let manager else { return [] }
        return manager.controllers.compactMap { controller in
            guard let window = controller.window, !manager.isIncognito(window: controller.state.id) else { return nil }
            return (controller.state.id, window)
        }
    }

    private func schedule(_ id: String) -> OpaquePointer? {
        if let schedule = schedules[id] { return schedule }
        guard let schedule = cmux_launch_image_schedule_new(0) else { return nil }
        schedules[id] = schedule
        return schedule
    }

    private static func shown(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// A frame, theme, workspace, tab or visibility change (each record save, the launch settle):
    /// every window notes it, and the timer waits for the first one due.
    func windowsChanged() {
        guard directory != nil, manager?.isTerminating == false else { return }
        let now = Self.nowMs
        let live = windows
        for (id, window) in live {
            guard let schedule = schedule(id) else { continue }
            _ = cmux_launch_image_schedule_note(schedule, Self.shown(window) ? 3 : 2, now)
            _ = cmux_launch_image_schedule_note(schedule, 1, now)
        }
        for id in Set(schedules.keys).subtracting(live.map(\.id)) { forget(id) }
        arm()
    }

    private func transition(_ window: NSWindow?, event: UInt32) {
        guard let window, let id = windows.first(where: { $0.window === window })?.id, let schedule = schedules[id] else { return }
        _ = cmux_launch_image_schedule_note(schedule, event, Self.nowMs)
        if event == 5 { _ = cmux_launch_image_schedule_note(schedule, 1, Self.nowMs) }
        arm()
    }

    /// Arms the timer for the earliest due capture.
    private func arm() {
        let now = Self.nowMs
        let due = schedules.values.compactMap { schedule -> UInt64? in
            let at = cmux_launch_image_schedule_note(schedule, 0, now) // an unknown event changes nothing: it reads the due time
            return at >= 0 ? UInt64(at) : nil
        }.min()
        guard let due else { timer.cancel(); return }
        timer.schedule(after: .milliseconds(Int(due > now ? due - now : 0))) { @MainActor [weak self] in self?.fire() }
    }

    private func fire() {
        let now = Self.nowMs
        for (id, window) in windows {
            guard let schedule = schedules[id], cmux_launch_image_schedule_take_due(schedule, now) else { continue }
            Task { await capture(id: id, window: window, schedule: schedule) }
        }
        arm()
    }

    /// The quit: every shown window changed since its last capture (or never captured) is captured
    /// now, before the launch record's last write.
    func captureForQuit() async {
        guard directory != nil else { return }
        timer.cancel()
        var captures: [Task<Void, Never>] = []
        for (id, window) in windows {
            guard let schedule = schedules[id], cmux_launch_image_schedule_take_quit(schedule) else { continue }
            captures.append(Task { await capture(id: id, window: window, schedule: schedule) })
        }
        for capture in captures { await capture.value }
    }

    /// A window the person closed: its images go with it (stub-decision.md 8).
    func windowClosed(_ id: String) {
        forget(id)
        guard let directory else { return }
        record.setImage(nil, forWindow: id)
        work.post(.bestEffort, mayBlock: .files) { _ = cmux_launch_image_remove_window(directory.path, id) }
    }

    private func forget(_ id: String) {
        if let schedule = schedules.removeValue(forKey: id) { cmux_launch_image_schedule_free(schedule) }
    }

    private func capture(id: String, window: NSWindow, schedule: OpaquePointer) async {
        guard let directory else { return }
        let epoch = cmux_launch_image_schedule_epoch(schedule)
        let number = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor
        let expected = (width: Int((window.frame.width * scale).rounded()), height: Int((window.frame.height * scale).rounded()))
        let live = windows.map(\.id)
        let published = try? await work.run(.userVisible, mayBlock: .files) { () -> Published? in
            guard let image = Self.windowImage(number), abs(image.width - expected.width) <= 1, abs(image.height - expected.height) <= 1,
                  let png = image.unfilteredPNGData() else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var out = CmuxLaunchImage()
            let ok = png.withUnsafeBytes { bytes in
                cmux_launch_image_publish(directory.path, id, bytes.bindMemory(to: UInt8.self).baseAddress, png.count, &out)
            }
            guard ok else { return nil }
            Self.prune(directory, live: live)
            return Published(generation: out.generation, pixelWidth: out.pixel_width, pixelHeight: out.pixel_height)
        }
        // The schedule is freed when its window closes; a capture that outlived it has nothing to report.
        guard schedules[id] == schedule else { return }
        guard let published = published ?? nil, cmux_launch_image_schedule_is_current(schedule, epoch) else {
            _ = cmux_launch_image_schedule_note(schedule, 6, Self.nowMs)
            arm()
            return
        }
        record.setImage(LaunchRecordImage(key: "\(build)/\(id)/\(published.generation)", pixelWidth: published.pixelWidth,
                                          pixelHeight: published.pixelHeight), forWindow: id)
        _ = cmux_launch_image_schedule_note(schedule, 7, Self.nowMs)
    }

    nonisolated private static func prune(_ directory: URL, live: [String]) {
        let strings = live.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let ids: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } }
        ids.withUnsafeBufferPointer { ids in
            _ = cmux_launch_image_prune(directory.path, ids.baseAddress, ids.count, UInt64(CMUX_LAUNCH_IMAGE_PRUNE_GRACE_MS))
        }
    }

    /// This process's own window (no Screen Recording grant needed). `CGWindowListCreateImage` is
    /// marked unavailable in the macOS 15 SDK, so it is resolved at run time, as the debug capture does.
    nonisolated private static func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id, options)?.takeRetainedValue()
    }
}
