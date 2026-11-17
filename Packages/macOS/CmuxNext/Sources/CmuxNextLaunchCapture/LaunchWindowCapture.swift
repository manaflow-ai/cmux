public import AppKit
public import CmuxNextBrowser
public import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import CmuxNextScreenshots
public import CmuxNextWakeups

/// What the app tells ``LaunchWindowCapture`` about its windows (`AppServices` answers, one-line forwards).
@MainActor
public protocol LaunchCaptureHost: AnyObject {
    /// Captures run: the windows are restored and the app is not quitting.
    var launchCaptureLive: Bool { get }
    /// The open windows.
    var launchCaptureWindowIDs: [String] { get }
    /// A capture may picture the window: never an incognito one.
    func launchCaptureAllows(_ id: String) -> Bool
    func launchCaptureWindow(_ id: String) -> NSWindow?
    /// The window's background (the theme's surface color), the plain fill of a page region.
    func launchCaptureBackground(_ id: String) -> CGColor?
    /// The Chromium browser pages window `id` shows in its panes, each with its cached hover picture.
    func launchCaptureBrowserPages(_ id: String) -> [LaunchCaptureBrowserPage]
    /// Where a publish names a window's image for the launch record, from any thread.
    var launchRecordImages: LaunchRecordImages { get }
    /// A window's image changed: the launch record is written again.
    func launchRecordChanged()
    /// A window closed: the record names no image for it.
    func launchRecordForget(_ id: String)
}

/// A browser page a window shows, with what the app keeps of it: its hover picture (at most
/// `PreviewImageCache.pagePixelSize`), when that was asked for, and the page version it shows.
public struct LaunchCaptureBrowserPage {
    public let tab: CEFTab
    public let picture: CGImage?
    public let takenAt: ContinuousClock.Instant?
    public let version: Int?

    public init(tab: CEFTab, picture: CGImage?, takenAt: ContinuousClock.Instant?, version: Int?) {
        self.tab = tab; self.picture = picture; self.takenAt = takenAt; self.version = version
    }
}

/// Each window's last committed frame, saved for the next launch's first frame (stage 0 of cmuxterm-hq
/// `docs/design/launch-shell-first.md`, piece 9). Owned by the app's `WindowManager`.
///
/// When: one Rust schedule per window (``LaunchImageSchedule``) is told the window's changes (frame,
/// theme, shown workspace or tab), visibility and transitions; a capture is due 750 ms after the last
/// change, never while the window is hidden or a transition runs, and once at quit for a window that
/// changed or has no capture from this run (``captureForQuit()``).
///
/// What: the window server's composite of the window and its page windows (no Screen Recording grant:
/// `NSWindow.compositedCapturePlan`, 34.2/35.5 ms p50/p95 off the main actor, longest main-thread turn
/// 0.2 ms, #45444), which shows the chrome and the terminals but only the fill of a Chromium page. Each
/// Chromium page region then gets the page's cached hover picture when Rust's age rule says it still
/// shows the page (``LaunchPageRegion``), else the theme's plain fill: no new page capture ever runs
/// (one measured 74.3/92.4 ms with a 9.5/10.8 ms main-thread turn), and no page is woken or made.
///
/// The main actor reads only window numbers, frames, page rectangles and cached images; the capture,
/// the composite and the PNG encode run off it, the publish on `BackgroundWork`'s files lane, where
/// `cmux_launch_image_publish_with` hands the image to the launch record only while the window has not
/// moved on since the capture began (``LaunchImageSchedule/whileCurrent(_:_:)``). Nothing here holds the
/// quit: the file work runs `.continueOnShutdown`. Failed captures in a row back off in Rust.
@MainActor
public final class LaunchWindowCapture {
    private weak var host: (any LaunchCaptureHost)?
    private let work: BackgroundWork
    /// Nil without a bundle id (tests): nothing is captured.
    private let store: LaunchImageStore?
    private var windows: [String: Window] = [:]
    /// The first capture of the run prunes the images of windows that no longer exist.
    private var pruned = false

    /// One window's schedule and its due timer.
    private final class Window {
        let schedule = LaunchImageSchedule()
        let timer = DemandTimer(owner: "launch-image.capture")
    }

    /// - Parameter bundleID: The app's; the images go to `<Application Support>/<bundle id>/launch-images`.
    public init(host: any LaunchCaptureHost, work: BackgroundWork, bundleID: String?) {
        self.host = host
        self.work = work
        store = bundleID.map(LaunchImageStore.init(bundleID:))
    }

    // MARK: Events

    /// The window's frame, shown workspace or shown tab changed.
    public func changed(_ id: String) { note(.changed, id) }

    /// The theme changed: every window looks different.
    public func themeChanged() {
        for id in liveWindowIDs() { note(.changed, id) }
    }

    /// The window was ordered in or out, minimized, or covered or uncovered.
    public func visibilityChanged(_ id: String, _ window: NSWindow) { note(Self.isShown(window) ? .shown : .hidden, id) }

    /// A live resize or a full screen transition began (they nest).
    public func transitionBegan(_ id: String) { note(.transitionBegan, id) }

    /// It ended.
    public func transitionEnded(_ id: String) { note(.transitionEnded, id) }

    /// The window closed: its schedule goes, and a capture in flight goes stale (it names nothing). With
    /// `keepImages` false (the person closed it) its images go too and the record names none; a window
    /// the app closed keeps them until a prune.
    public func windowClosed(_ id: String, keepImages: Bool) {
        if let entry = windows.removeValue(forKey: id) {
            entry.timer.cancel()
            _ = entry.schedule.note(.hidden, at: LaunchCaptureClock.now())
        }
        guard !keepImages, let host, let store else { return }
        host.launchRecordForget(id)
        let work = work
        // task-owner: one file removal on the files lane; nothing awaits it.
        Task { _ = try? await work.run(.bestEffort, mayBlock: .files, shutdown: .continueOnShutdown) { store.removeWindow(id) } }
    }

    /// At quit: each shown, settled window that changed since its last capture, or has none from this run,
    /// is captured once from what is on screen and cached now. Nothing waits for it: a publish that ends
    /// before the launch record's last write is named there; one that does not leaves the previous image,
    /// which the store keeps.
    public func captureForQuit() {
        guard let host, host.launchCaptureLive, store != nil else { return }
        let now = LaunchCaptureClock.now()
        for id in liveWindowIDs() {
            let entry = window(id, at: now)
            entry.timer.cancel()
            if entry.schedule.takeQuit() { capture(id, entry, at: now) }
        }
    }

    // MARK: Schedule

    private func note(_ event: LaunchImageSchedule.Event, _ id: String) {
        guard let host, host.launchCaptureLive, store != nil, host.launchCaptureAllows(id) else { return }
        let now = LaunchCaptureClock.now()
        let entry = window(id, at: now)
        arm(entry, id, due: entry.schedule.note(event, at: now), now: now)
    }

    /// `id`'s schedule, made on first use; a new one is told whether the window shows now (a new schedule
    /// is hidden).
    private func window(_ id: String, at now: UInt64) -> Window {
        if let entry = windows[id] { return entry }
        let entry = Window()
        windows[id] = entry
        if let window = host?.launchCaptureWindow(id), Self.isShown(window) { _ = entry.schedule.note(.shown, at: now) }
        return entry
    }

    private func arm(_ entry: Window, _ id: String, due: UInt64?, now: UInt64) {
        guard let due else { return entry.timer.cancel() }
        let wait = due > now ? due - now : 0
        entry.timer.schedule(after: .milliseconds(Int64(clamping: wait))) { @MainActor [weak self] in self?.fire(id) }
    }

    private func fire(_ id: String) {
        guard let host, host.launchCaptureLive, let entry = windows[id] else { return }
        let now = LaunchCaptureClock.now()
        guard entry.schedule.takeDue(at: now) else { return }
        capture(id, entry, at: now)
    }

    /// The open windows a capture may picture.
    private func liveWindowIDs() -> [String] {
        guard let host else { return [] }
        return host.launchCaptureWindowIDs.filter(host.launchCaptureAllows)
    }

    private static func isShown(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    // MARK: Capture

    /// Starts one capture of `id`; it reports to the schedule when it ends.
    private func capture(_ id: String, _ entry: Window, at now: UInt64) {
        let schedule = entry.schedule
        guard let host, let store, host.launchCaptureAllows(id), let window = host.launchCaptureWindow(id) else {
            windows.removeValue(forKey: id)?.timer.cancel() // gone, or not to be pictured: no schedule
            return
        }
        guard let plan = window.compositedCapturePlan(includeChild: WindowOverlayHost.isPageWindow) else {
            arm(entry, id, due: schedule.note(.captureFailed, at: now), now: now)
            return
        }
        pruneOnce(host, store)
        let epoch = schedule.epoch
        let size = window.frame.size, scale = window.backingScaleFactor
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let fill = host.launchCaptureBackground(id).flatMap(Self.fillImage)
        let layers = fill.map { pageLayers(in: window, pages: host.launchCaptureBrowserPages(id), fill: $0, compositeAt: now) } ?? []
        let images = host.launchRecordImages
        let work = work
        // task-owner: one capture; it ends with its publish (the schedule drops a stale one).
        Task { [weak self] in
            let png = await Self.render(plan, width: width, height: height, windowSize: size, layers: layers)
            var outcome: (written: Bool, handed: Bool) = (false, false)
            if let png {
                outcome = (try? await work.run(.bestEffort, mayBlock: .files, shutdown: .continueOnShutdown) { () -> (Bool, Bool) in
                    var handed = false
                    let written = store.publish(windowID: id, png: png) { image in
                        handed = schedule.whileCurrent(epoch) { images.set(image, forWindow: id) }
                    } != nil
                    return (written, handed)
                }) ?? (false, false)
            }
            self?.captureEnded(id, schedule: schedule, epoch: epoch, written: outcome.written, handed: outcome.handed)
        }
    }

    /// A capture ended: handed to the record (done), wrote nothing while still current (failed: due again),
    /// or went stale (the event that made it so already armed the next one).
    private func captureEnded(_ id: String, schedule: LaunchImageSchedule, epoch: UInt64, written: Bool, handed: Bool) {
        let now = LaunchCaptureClock.now()
        let due: UInt64?
        if handed {
            due = schedule.note(.captureDone, at: now)
            host?.launchRecordChanged()
        } else if !written, schedule.whileCurrent(epoch, {}) {
            due = schedule.note(.captureFailed, at: now)
        } else {
            return
        }
        guard let host, host.launchCaptureLive, let entry = windows[id], entry.schedule === schedule else { return }
        arm(entry, id, due: due, now: now)
    }

    /// The Chromium page regions of `window`, bottom first: each browser page's cached hover picture where
    /// Rust's age rule allows it, else `fill`; the app's own Chromium pages (the agent page, Settings) keep no
    /// versioned image while they run, so they are `fill`. The window server's composite has only their
    /// background there, never their text.
    private func pageLayers(in window: NSWindow, pages: [LaunchCaptureBrowserPage], fill: CGImage, compositeAt: UInt64) -> [WindowImageLayer] {
        var layers: [WindowImageLayer] = []
        for page in pages {
            let tab = page.tab, view = page.tab.contentView
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let rect = tab.devToolsDiagnosticFrames.map { window.convertFromScreen($0.page) } ?? view.convert(view.bounds, to: nil)
            guard rect.width > 0, rect.height > 0 else { continue }
            let region = LaunchPageRegion(imageTakenAt: page.picture == nil ? nil : page.takenAt.map(LaunchCaptureClock.milliseconds),
                                          imageVersion: page.version, pageVersion: tab.state.pictureVersion,
                                          pageChangedAt: nil, compositeAt: compositeAt)
            layers.append(.page(Self.regionImage(cached: page.picture, region: region, fill: fill), rect,
                                holes: tab.pageWindowHoles.map { view.convert($0, to: nil) }, clip: WindowImageClip(tab.pageWindowClip)))
        }
        for (page, rect) in PageRegistry.shownChromiumPages(in: window) {
            layers.append(.page(fill, rect, holes: page.chromiumWindowHoles, clip: WindowImageClip(page.chromiumWindowClip)))
        }
        return layers
    }

    /// What a Chromium page region shows: its cached image when Rust's age rule allows it, else the plain fill.
    nonisolated static func regionImage(cached: CGImage?, region: LaunchPageRegion, fill: CGImage) -> CGImage {
        guard let cached, region.paintsImage else { return fill }
        return cached
    }

    /// The window server's image of `plan` at `width` x `height`, the page layers painted over it, as PNG; nil
    /// when the window server gave none. Off the main actor.
    @concurrent
    nonisolated static func render(_ plan: WindowCapturePlan, width: Int, height: Int, windowSize: CGSize,
                                   layers: [WindowImageLayer]) async -> Data? {
        guard let base = NSWindow.capture(plan)?.resampled(width: width, height: height) else { return nil }
        return compose(base: base, windowSize: windowSize, layers: layers).pngData()
    }

    /// `base` (the window server's image of a window `windowSize` points large) with the page layers painted
    /// over it, bottom first; `base` itself without layers. Any thread.
    nonisolated static func compose(base: CGImage, windowSize: CGSize, layers: [WindowImageLayer]) -> CGImage {
        WindowImageLayer.composite(base: base, windowSize: windowSize, layers: layers) ?? base
    }

    /// A 1 x 1 image of the color, drawn stretched over a plain region.
    nonisolated static func fillImage(_ color: CGColor) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }

    /// Once per run, the images of windows that no longer exist go (each file once older than the store's
    /// grace, so a window opened since is safe).
    private func pruneOnce(_ host: any LaunchCaptureHost, _ store: LaunchImageStore) {
        guard !pruned else { return }
        pruned = true
        let live = liveWindowIDs()
        let work = work
        // task-owner: one prune on the files lane; nothing awaits it.
        Task { _ = try? await work.run(.bestEffort, mayBlock: .files, shutdown: .continueOnShutdown) { store.prune(live: live) } }
    }
}
