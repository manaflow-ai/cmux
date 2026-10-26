public import AppKit
import CmuxNextWakeups
import Foundation

/// Follows the macOS desktop picture: its color for ``WallpaperTint`` (`appearance.wallpaperTint`)
/// and, for the Desktop Wallpaper background (``BackdropSelection/desktop``), the picture itself.
///
/// macOS posts nothing public when the picture changes, so the watch re-reads
/// `NSWorkspace.desktopImageURL(for:)` when one could have: a Space switch (each Space has its own
/// picture), a screen change, waking, the app coming to the front (the person picked a picture in
/// System Settings), another window becoming key or a window moving to another display (the main
/// screen may now be a different one), the light or dark appearance flipping, macOS's own
/// `com.apple.desktop` notice, and a write to the wallpaper store
/// (`~/Library/Application Support/com.apple.wallpaper/Store`). A read that matches the last one
/// costs nothing more; a new picture is decoded small and averaged off the main actor, once per
/// picture (switching back to a Space reuses its color). Registered material views re-apply with
/// the result. It reads the main screen (the one with the key window); every window takes that
/// screen's color. Inert until ``start()``, so tests and windows built before launch see no tint.
///
/// ```swift
/// DesktopWallpaperWatch.shared.start()
/// let tint = DesktopWallpaperWatch.shared.tint
/// ```
@MainActor
public final class DesktopWallpaperWatch {
    /// The app's watch over the main screen's desktop picture.
    public static let shared = DesktopWallpaperWatch(read: DesktopWallpaperWatch.readMainScreen, sample: DesktopWallpaperWatch.sample,
                                                     defaults: .standard)
    /// Where the last color is kept, so the next launch's first window has it before a sample.
    static let lastTintKey = "cmux.wallpaperTint.last"

    /// What the desktop shows: the picture macOS reports, when it was last written, its fill color,
    /// and the appearance (a dynamic picture has a frame for each).
    nonisolated struct Reading: Hashable, Sendable {
        let picture: DesktopPicture
        let dark: Bool
        /// The reported file's modification date: a picture overwritten in place is a new picture.
        let modified: Date?

        /// - Parameters:
        ///   - picture: The picture macOS reports.
        ///   - dark: Whether the app is in the dark appearance.
        init(picture: DesktopPicture, dark: Bool) {
            self.picture = picture
            self.dark = dark
            // A fresh stat each time: the URL's own resource values can be a cached copy from before the overwrite.
            modified = picture.reportedURL.flatMap { url in
                url.isFileURL ? (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date : nil
            }
        }

        static func == (lhs: Reading, rhs: Reading) -> Bool {
            lhs.picture.reportedURL == rhs.picture.reportedURL && lhs.modified == rhs.modified && lhs.picture.fill == rhs.picture.fill
                && lhs.dark == rhs.dark
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(picture.reportedURL)
            hasher.combine(modified)
            hasher.combine(picture.fill.red)
            hasher.combine(picture.fill.green)
            hasher.combine(picture.fill.blue)
            hasher.combine(dark)
        }
    }

    /// The desktop picture's color now; nil until the first sample lands, or when it can't be read.
    public private(set) var tint: WallpaperTint?
    /// Bumped each time the desktop shows something new after the first reading: a view showing
    /// the Desktop Wallpaper background reloads it once per bump (``BackdropImageStore``).
    public private(set) var generation = 0
    /// Samples taken (tests).
    private(set) var sampleCount = 0

    private let read: @MainActor () -> Reading?
    private let sample: @Sendable (Reading) async -> WallpaperTint?
    private let defaults: UserDefaults?
    private var current: Reading?
    /// Colors already sampled, by reading: a Space switch back never decodes again.
    private var colors: [Reading: WallpaperTint?] = [:]
    /// Samples under way, by start order: the newest one is the current reading's; older ones are
    /// cancelled and drop out when they return, so `settled()` can wait for them too.
    private var samples: [Int: Task<Void, Never>] = [:]
    private var samplesStarted = 0
    private let storeSettle = DemandTimer(owner: "desktop-wallpaper-store")
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var storeSource: (any DispatchSourceFileSystemObject)?
    private let views = NSHashTable<WindowMaterialView>.weakObjects()

    /// - Parameters:
    ///   - read: What the desktop shows now; nil without a screen.
    ///   - sample: The color of a reading, off the main actor.
    ///   - defaults: Where the last color is kept between launches; nil keeps none.
    init(read: @escaping @MainActor () -> Reading?, sample: @escaping @Sendable (Reading) async -> WallpaperTint?,
         defaults: UserDefaults? = nil) {
        self.read = read
        self.sample = sample
        self.defaults = defaults
    }

    /// Starts following the desktop: one reading now, then one per event that could change it.
    /// Calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        // The last launch's color stands in until this launch's sample lands.
        if let last = defaults?.array(forKey: Self.lastTintKey) as? [Double], last.count == 3 {
            tint = WallpaperTint(red: last[0], green: last[1], blue: last[2])
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observe(name, in: workspace)
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            observe(name, in: .default)
        }
        // macOS's own notices: a new picture, and the light or dark appearance.
        for name in ["com.apple.desktop", "AppleInterfaceThemeChangedNotification"] {
            observe(Notification.Name(name), in: DistributedNotificationCenter.default())
        }
        watchStore()
        refresh()
    }

    /// Makes `view` re-apply its backdrop with each new reading, until it is deallocated.
    func register(_ view: WindowMaterialView) {
        views.add(view)
    }

    /// Re-applies every registered view (the setting changed).
    public func refreshViews() {
        for view in views.allObjects { view.desktopWallpaperDidChange() }
    }

    /// Reads the desktop again once a view sees the light or dark appearance flip (after
    /// ``start()``): macOS's `AppleInterfaceThemeChangedNotification` can arrive before the app's
    /// appearance changes, so that reading still saw the old one.
    func appearanceDidChange() {
        guard !observers.isEmpty else { return }
        refresh()
    }

    /// Reads the desktop; a new reading takes its color (sampled once) and re-applies the views.
    func refresh() {
        guard let reading = read(), reading != current else { return }
        if current != nil { generation += 1 }
        current = reading
        for task in samples.values { task.cancel() }
        if let known = colors[reading] { return publish(known) }
        sampleCount += 1
        let sample = self.sample, id = samplesStarted
        samplesStarted += 1
        // task-owner: one sample per new reading; a newer reading cancels it (refresh above)
        samples[id] = Task { [weak self] in
            let color = await sample(reading)
            guard let self else { return }
            self.samples[id] = nil
            guard !Task.isCancelled, self.current == reading else { return }
            if self.colors.count >= 32 { self.colors.removeAll() }
            self.colors[reading] = color
            self.publish(color)
        }
    }

    /// Waits for every sample under way, cancelled ones too (tests).
    func settled() async {
        while let task = samples.values.first { await task.value }
    }

    private func publish(_ color: WallpaperTint?) {
        tint = color
        if let color { defaults?.set([color.red, color.green, color.blue], forKey: Self.lastTintKey) }
        refreshViews()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // main-proof: the observer runs on the main queue (queue: .main)
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((center, observer))
    }

    /// The wallpaper store's folder: macOS rewrites its index there when a picture is chosen. A
    /// burst of writes settles before one reading, so the reading sees the new picture.
    private func watchStore() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let store = library.appendingPathComponent("Application Support/com.apple.wallpaper/Store", isDirectory: true)
        let descriptor = open(store.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // main-proof: the source delivers on the main queue (queue: .main)
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        storeSource = source
    }

    private func storeDidChange() {
        storeSettle.schedule(after: .milliseconds(300)) { @MainActor [weak self] in
            self?.refresh()
        }
    }

    /// The main screen's desktop picture (the screen with the key window) in the app's appearance.
    private static func readMainScreen() -> Reading? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return Reading(picture: DesktopPicture(screen: screen), dark: dark)
    }

    /// The reading's picture resolved to a file, decoded small and averaged, off the main actor.
    nonisolated static func sample(_ reading: Reading) async -> WallpaperTint? {
        await Task.detached(priority: .utility) {
            guard let url = reading.picture.resolvedURL(dark: reading.dark),
                  let image = BackdropImageStore.decode(url, maxPixelSize: 64, dark: reading.dark) else { return nil }
            return WallpaperTint.average(of: image)
        }.value
    }
}
