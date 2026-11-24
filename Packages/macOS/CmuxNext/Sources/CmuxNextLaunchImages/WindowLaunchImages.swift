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
public final class WindowLaunchImages {
    /// The windows the store keeps: open and not incognito, by id (the app's window manager).
    private let liveWindows: @MainActor () -> [(id: String, window: NSWindow)]
    /// True once the app is quitting: no new captures but the quit's own.
    private let isTerminating: @MainActor () -> Bool
    private let work: BackgroundWork
    private let record: AppLaunchRecord
    /// `<support>/launch-images`, nil with no bundle id (as the launch record). Lives as long as the app.
    private struct Published: Sendable { let generation: UInt64; let pixelWidth: UInt32; let pixelHeight: UInt32 }
    private let directory: URL?
    private let build: String
    private var schedules: [String: OpaquePointer] = [:]
    private let timer = DemandTimer(owner: "WindowLaunchImages")
    /// Windows in a live resize or full screen transition when last seen: captured once it ends.
    private var resizing: Set<String> = []

    /// The system's appearance, as stage 0 reads it before the app sets its own (`LaunchShell.prepare`).
    public static var systemIsDark: Bool {
        if NSApp.appearance == nil { return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    public init(windows: @escaping @MainActor () -> [(id: String, window: NSWindow)], isTerminating: @escaping @MainActor () -> Bool,
                work: BackgroundWork, record: AppLaunchRecord, bundleID: String?) {
        liveWindows = windows
        self.isTerminating = isTerminating
        self.work = work
        self.record = record
        build = LaunchShellPaths.build(info: Bundle.main.infoDictionary ?? [:])
        directory = bundleID.map { LaunchShellPaths.images(in: LaunchTimesFile.supportDirectory(bundleID: $0)) }
    }

    private static var nowMs: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    private var windows: [(id: String, window: NSWindow)] { liveWindows() }

    private func schedule(_ id: String) -> OpaquePointer? {
        if let schedule = schedules[id] { return schedule }
        guard let schedule = cmux_launch_image_schedule_new(0) else { return nil }
        schedules[id] = schedule
        return schedule
    }

    private static func shown(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// A frame, theme, workspace, tab or visibility change (each record save, an occlusion change, the launch
    /// settle): every window notes it, and the timer waits for the first one due. A live resize or full screen
    /// transition (`Motion.isLiveResizing`, the app's one tracker) holds the window's capture until it ends; the
    /// record save at its end lands here. A window gone while the app runs was closed: its images go with it
    /// (stub-decision.md 8).
    public func windowsChanged() {
        guard directory != nil, !isTerminating() else { return }
        let now = Self.nowMs
        let live = windows
        for (id, window) in live {
            guard let schedule = schedule(id) else { continue }
            let inResize = Motion.isLiveResizing(window)
            if inResize, resizing.insert(id).inserted { _ = cmux_launch_image_schedule_note(schedule, 4, now) }
            if !inResize, resizing.remove(id) != nil { _ = cmux_launch_image_schedule_note(schedule, 5, now) }
            _ = cmux_launch_image_schedule_note(schedule, Self.shown(window) ? 3 : 2, now)
            _ = cmux_launch_image_schedule_note(schedule, 1, now)
        }
        for id in Set(schedules.keys).subtracting(live.map(\.id)) { windowClosed(id) }
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
    public func captureForQuit() async {
        guard directory != nil else { return }
        timer.cancel()
        var captures: [Task<Void, Never>] = []
        for (id, window) in windows {
            guard let schedule = schedules[id], cmux_launch_image_schedule_take_quit(schedule) else { continue }
            captures.append(Task { await capture(id: id, window: window, schedule: schedule) })
        }
        for capture in captures { await capture.value }
    }

    /// A window closed: its schedule, record key and images go with it (stub-decision.md 8).
    private func windowClosed(_ id: String) {
        forget(id)
        resizing.remove(id)
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
            guard let image = NSWindow.windowServerImage(of: Int(number)), abs(image.width - expected.width) <= 1, abs(image.height - expected.height) <= 1,
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

    /// The launch record's entry for `window` (`WindowRecordSaver`): its frame and display, its backdrop colour
    /// (`background`), its last frame's image, its workspace and shown tabs, stamped for stage 0.
    public static func snapshot(id: String, window: NSWindow, background color: ThemeRGB, image: LaunchRecordImage?,
                                workspaceID: String, tabIDs: [String]) -> LaunchRecordWindowSnapshot {
        let rgba = (LayoutCacheTheme.byte(color.red), LayoutCacheTheme.byte(color.green), LayoutCacheTheme.byte(color.blue), LayoutCacheTheme.byte(color.alpha))
        return stamped(LaunchRecordWindowSnapshot(id: id, frame: window.frame, displayID: LayoutCacheDisplay.id(of: window.screen),
            backgroundRGBA: rgba, barRGBA: rgba, imageKey: image?.key ?? "", imagePixelSize: (image?.pixelWidth ?? 0, image?.pixelHeight ?? 0),
            workspaceID: workspaceID, tabIDs: tabIDs), for: window)
    }

    /// `snapshot` with what stage 0 checks before it draws the image (cmux-launch-shell `plan`): the display's
    /// frame and scale, the system's appearance (the record's is compared with the launch's), full screen.
    static func stamped(_ snapshot: LaunchRecordWindowSnapshot, for window: NSWindow) -> LaunchRecordWindowSnapshot {
        var snapshot = snapshot
        snapshot.backingScale = Double(window.screen?.backingScaleFactor ?? 0)
        snapshot.screenFrame = window.screen?.frame ?? .zero
        snapshot.appearance = systemIsDark ? 1 : 0
        snapshot.appearanceFollowsSystem = true
        snapshot.fullscreen = window.styleMask.contains(.fullScreen)
        return snapshot
    }
}
