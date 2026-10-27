public import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Follows the macOS desktop picture: its color for ``WallpaperTint`` (`appearance.wallpaperTint`)
/// and, for the Desktop Wallpaper background (``BackdropSelection/desktop``), the picture itself.
///
/// macOS posts nothing public when the picture changes, so the watch re-reads
/// `NSWorkspace.desktopImageURL(for:)` when one could have: a write to the wallpaper store
/// (`~/Library/Application Support/com.apple.wallpaper/Store`, which macOS rewrites when a
/// picture is chosen or shuffles), macOS's own `com.apple.desktop` notice, a Space switch (each
/// Space has its own picture), a screen change, waking, and another window becoming key or a
/// window moving to another display (the main screen may now be a different one). A view
/// that sees the light or dark appearance flip asks too (``appearanceDidChange()``). A read that
/// matches the last one costs nothing more; a new picture is decoded small and averaged off the
/// main actor, once per picture (switching back to a Space reuses its color), and only while
/// ``tintEnabled``. Registered material views re-apply at once (the Desktop Wallpaper art) and
/// again when the color lands. One decode runs at a time. While nothing of the app shows (hidden,
/// or no visible window) it does nothing: the first event after it shows again (the unhide, a
/// window's visibility changing) reads once. It reads the main screen (the one with the key window); every
/// window takes that screen's color. Inert until ``start()``, so tests and windows built before
/// launch see no tint. The app's watch belongs to ``BackdropImageStore/shared``.
///
/// ```swift
/// BackdropImageStore.shared.desktop.start()
/// let tint = BackdropImageStore.shared.desktop.tint
/// ```
@MainActor
public final class DesktopWallpaperWatch {
    /// A watch over the main screen's desktop picture that keeps its last color in `defaults`.
    public static func live(defaults: UserDefaults? = .standard) -> DesktopWallpaperWatch {
        DesktopWallpaperWatch(read: readMainScreen, sample: sample, defaults: defaults, isHidden: showsNoWindow)
    }

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
                url.isFileURL ? (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date : nil
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
    /// `appearance.wallpaperTint`: the tint leans toward the picture, and pictures are sampled,
    /// only while on. Turning it on samples the picture shown now.
    public var tintEnabled = false {
        didSet {
            guard tintEnabled != oldValue else { return }
            // Off: a sample under way finishes into the cache but publishes nothing.
            if !tintEnabled || !sampleIfNeeded() { refreshViews() }
        }
    }

    private let read: @MainActor () -> Reading?
    private let sample: @Sendable (Reading) async -> WallpaperTint?
    private let defaults: UserDefaults?
    private let isHidden: @MainActor () -> Bool
    private var current: Reading?
    /// The reading whose color ``tint`` is.
    private var published: Reading?
    /// Colors already sampled, by reading: a Space switch back never decodes again.
    private var colors: [Reading: WallpaperTint?] = [:]
    /// The one sample under way. A decode can't be stopped once it runs, so a newer reading never
    /// starts a second one: it waits, and this one's end samples the reading shown then.
    private var sampling: (reading: Reading, task: Task<Void, Never>)?
    private let storeSettle = DemandTimer(owner: "desktop-wallpaper-store")
    private var observers: [MainActorObservation] = []
    private var storeSource: WallpaperStoreSource?
    private let views = NSHashTable<WindowMaterialView>.weakObjects()

    /// - Parameters:
    ///   - read: What the desktop shows now; nil without a screen.
    ///   - sample: The color of a reading, off the main actor.
    ///   - defaults: Where the last color is kept between launches; nil keeps none.
    ///   - isHidden: Whether nothing of the app shows (hidden, or no visible window): no reading then.
    init(read: @escaping @MainActor () -> Reading?, sample: @escaping @Sendable (Reading) async -> WallpaperTint?,
         defaults: UserDefaults? = nil, isHidden: @escaping @MainActor () -> Bool = { false }) {
        self.read = read
        self.sample = sample
        self.defaults = defaults
        self.isHidden = isHidden
    }

    /// Starts following the desktop: one reading now, then one per event that could change it.
    /// Calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        // The last launch's color stands in until this launch's sample lands.
        if let last = defaults?.array(forKey: Self.lastTintKey) as? [Double], last.count == 3 {
            tint = WallpaperTint(red: last[0], green: last[1], blue: last[2])
        }
        // A new picture shows as a store write (watchStore) or macOS's notice; the rest are the
        // moments the main screen's picture can differ without one.
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            MainActorObservation(Notification.Name("com.apple.desktop"), center: DistributedNotificationCenter.default()) { [weak self] in
                self?.refresh()
            },
            MainActorObservation(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { [weak self] in self?.refresh() },
            MainActorObservation(NSWorkspace.didWakeNotification, center: workspace) { [weak self] in self?.refresh() },
            MainActorObservation(NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refresh() },
            // A window shown, unhidden or uncovered (a panel that never becomes key too).
            MainActorObservation(NSWindow.didChangeOcclusionStateNotification) { [weak self] in self?.refresh() },
            MainActorObservation(NSWindow.didBecomeKeyNotification) { [weak self] in self?.refresh() },
            MainActorObservation(NSWindow.didChangeScreenNotification) { [weak self] in self?.refresh() },
        ]
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
    /// ``start()``): a dynamic picture has a frame for each.
    func appearanceDidChange() {
        guard !observers.isEmpty else { return }
        refresh()
    }

    /// Reads the desktop (not while the app is hidden); a new reading re-applies the views at once
    /// and, while ``tintEnabled``, takes its color (sampled once).
    func refresh() {
        // A store that could not be watched again (macOS had not made it yet) is tried on each event.
        if storeSource == nil, !observers.isEmpty { watchStore() }
        guard !isHidden(), let reading = read() else { return }
        // The same picture: nothing moved, but a color that landed while nothing showed shows now.
        guard reading != current else {
            sampleIfNeeded()
            return
        }
        if current != nil { generation += 1 }
        current = reading
        // The Desktop Wallpaper art reloads now, not only once the color lands.
        if !sampleIfNeeded() { refreshViews() }
    }

    /// Takes the current reading's color while the tint is on: a known one at once (returns
    /// true: the views re-applied), else one sample off the main actor, when none is under way.
    @discardableResult
    private func sampleIfNeeded() -> Bool {
        guard tintEnabled, let reading = current, published != reading, !isHidden() else { return false }
        if let known = colors[reading] {
            publish(known, for: reading)
            return true
        }
        guard sampling == nil else { return false }
        sampleCount += 1
        let sample = self.sample
        // task-owner: the one sample under way (`sampling`); its end starts the next one if needed
        let task = Task { [weak self] in
            let color = await sample(reading)
            self?.sampled(color, for: reading)
        }
        sampling = (reading, task)
        return false
    }

    /// A sample ended: its color is kept for its reading, and shown only when that reading is
    /// still the desktop, the tint is on and the app shows; otherwise the reading shown now is
    /// sampled (the next refresh, once the app shows again).
    private func sampled(_ color: WallpaperTint?, for reading: Reading) {
        sampling = nil
        if colors.count >= 32 { colors.removeAll() }
        colors[reading] = color
        sampleIfNeeded()
    }

    /// Waits until no sample is under way (tests).
    func settled() async {
        while let task = sampling?.task { await task.value }
    }

    private func publish(_ color: WallpaperTint?, for reading: Reading) {
        tint = color
        published = reading
        if let color { defaults?.set([color.red, color.green, color.blue], forKey: Self.lastTintKey) }
        refreshViews()
    }

    /// The wallpaper store's folder: macOS rewrites its index there when a picture is chosen. A
    /// burst of writes settles before one reading, so the reading sees the new picture.
    /// A store that macOS replaced (the folder renamed or deleted) is watched again at its path.
    private func watchStore() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let store = library.appendingPathComponent("Application Support/com.apple.wallpaper/Store", isDirectory: true)
        storeSource = WallpaperStoreSource(store) { [weak self] replaced in self?.storeDidChange(replaced: replaced) }
    }

    private func storeDidChange(replaced: Bool) {
        // The source that saw the folder go is spent: drop it now, so the settled refresh (or any
        // later event, if macOS makes the folder later) watches the new one.
        if replaced { storeSource = nil }
        storeSettle.schedule(after: .milliseconds(300)) { @MainActor [weak self] in
            self?.refresh()
        }
    }

    /// Nothing of the app shows: it is hidden, or has no visible window.
    private static func showsNoWindow() -> Bool {
        guard let app = NSApp else { return true }
        return app.isHidden || !app.windows.contains { $0.isVisible }
    }

    /// The main screen's desktop picture (the screen with the key window) in the app's appearance.
    private static func readMainScreen() -> Reading? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return Reading(picture: DesktopPicture(screen: screen), dark: dark)
    }

    /// The reading's picture resolved to a file, decoded small (64 px) and averaged, off the main actor.
    nonisolated static func sample(_ reading: Reading) async -> WallpaperTint? {
        await Task.detached(priority: .utility) { () -> WallpaperTint? in
            guard let url = reading.picture.resolvedURL(dark: reading.dark),
                  let image = BackdropImageStore.decode(url, maxPixelSize: 64, dark: reading.dark) else { return nil }
            return WallpaperTint.average(of: image)
        }.value
    }
}
