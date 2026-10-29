public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups

/// Keeps destruction's main-actor hop in a small AppKit lifecycle seam.
private final class DisplayBackdropDeinitAdapter {
    weak var owner: DisplayBackdropBinding?

    nonisolated func run() {
        MainActor.assumeIsolated { owner?.teardown() } // main-proof: AppKit owns this binding on the main actor.
    }
}

/// Applies a display background between the app and room scopes. Explicit window and workspace
/// choices still win. The window owner calls ``stop()`` when it tears down.
@MainActor
public final class DisplayBackdropBinding {
    private let scope: ThemeScope
    private let displayScope: ThemeScope
    private let inheritedScope: ThemeScope
    private let center: NotificationCenter
    private let displayID: () -> String?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let listFolder: @Sendable (String) async -> [BackdropSelection]
    private let deinitAdapter: DisplayBackdropDeinitAdapter
    private let recordObserver: ((Notification.Name, AnyObject?, OperationQueue?) -> Void)?
    private let recordRemoval: (() -> Void)?
    private let timer = DemandTimer(owner: "display-backdrop")
    private var observers: [NSObjectProtocol] = []
    private var root: JSONValue = [:]
    private var stopped = false
    private var generation = 0
    private var folders: [String: (task: Task<[BackdropSelection], Never>, expires: Date, pictures: [BackdropSelection]?)] = [:]
    private(set) var folderRefresh: Task<Void, Never>?

    public init(window: NSWindow, scope: ThemeScope, center: NotificationCenter = .default,
                displayID: @escaping () -> String?, now: @escaping () -> Date = Date.init,
                calendar: @escaping () -> Calendar = { .current },
                listFolder: @escaping @Sendable (String) async -> [BackdropSelection] = DisplayBackdropBinding.readFolder,
                recordObserver: ((Notification.Name, AnyObject?, OperationQueue?) -> Void)? = nil,
                recordRemoval: (() -> Void)? = nil) {
        self.scope = scope; self.center = center; self.displayID = displayID; self.now = now; self.calendar = calendar
        self.listFolder = listFolder
        self.deinitAdapter = DisplayBackdropDeinitAdapter()
        self.recordObserver = recordObserver
        self.recordRemoval = recordRemoval
        inheritedScope = scope.parent ?? .app
        displayScope = ThemeScope(level: .room, parent: inheritedScope)
        scope.setParent(displayScope)
        deinitAdapter.owner = self
        let names: [Notification.Name] = [NSWindow.didChangeScreenNotification, .NSSystemClockDidChange,
                                         .NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
        for name in names {
            // Never make a notification's posting thread wait for the UI actor (SwiftUI can hold its render lock).
            recordObserver?(name, name == NSWindow.didChangeScreenNotification ? window : nil, nil)
            observers.append(center.addObserver(forName: name, object: name == NSWindow.didChangeScreenNotification ? window : nil,
                                                queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    nonisolated deinit {
        deinitAdapter.run()
    }

    /// Resolves and lists a folder on the global executor, including all symlink and metadata reads.
    @concurrent public nonisolated static func readFolder(_ path: String) async -> [BackdropSelection] {
        guard !Task.isCancelled else { return [] }
        return BackdropUserImages(folder: URL(fileURLWithPath: path, isDirectory: true)).list().sorted { $0.id < $1.id }
    }

    public func apply(_ root: JSONValue) {
        self.root = root
        // Bound cached/in-flight listings to configured folders; a removed folder cannot keep work alive.
        let paths = Set((root.value(at: ["appearance", "displayBackgrounds"])?.objectValue ?? [:]).values
            .compactMap { $0.stringValue.flatMap(BackdropSelectionSetting.folderPath) })
        for path in Array(folders.keys) where !paths.contains(path) {
            folders.removeValue(forKey: path)?.task.cancel()
        }
        refresh()
    }

    public func stop() {
        teardown()
    }

    fileprivate func teardown() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        timer.cancel()
        folderRefresh?.cancel()
        folderRefresh = nil
        for folder in folders.values { folder.task.cancel() }
        folders.removeAll()
        observers.forEach { center.removeObserver($0); recordRemoval?() }
        observers.removeAll()
        displayScope.pinBackdrop(.inherit)
        if scope.parent === displayScope { scope.setParent(inheritedScope) }
    }

    private func refresh() {
        guard !stopped else { return }
        generation += 1
        timer.cancel()
        folderRefresh?.cancel()
        folderRefresh = nil
        let values = root.value(at: ["appearance", "displayBackgrounds"])?.objectValue
        guard let id = displayID(), let raw = values?[id]?.stringValue else {
            displayScope.pinBackdrop(.inherit)
            return
        }
        guard raw != "none" else { displayScope.pinBackdrop(.none); return }
        let rotation = root.value(at: ["appearance", "displayBackgroundRotations"])?.objectValue?[id]?.stringValue
            .flatMap(BackdropRotation.init(rawValue:)) ?? .defaultRotation
        if let path = BackdropSelectionSetting.folderPath(raw) {
            refreshFolder(path, rotation: rotation)
        } else if raw == BackdropSelectionSetting.dailyID {
            let turn = BackdropShuffle(source: .paintings, rotation: rotation).turn(at: now(), calendar: calendar())
            displayScope.pinBackdrop(turn.picture.map(BackdropPin.selection) ?? .none)
            schedule(after: turn.wait)
        } else {
            displayScope.pinBackdrop(BackdropSelection(id: raw).map(BackdropPin.selection) ?? .inherit)
        }
    }

    private func refreshFolder(_ path: String, rotation: BackdropRotation) {
        // A pending read is shared across refreshes. Completed listings expire at the next rotation,
        // so screen/settings changes reuse them while additions and removals appear on the next turn.
        if let expires = folders[path]?.expires, expires <= now() {
            folders.removeValue(forKey: path)?.task.cancel()
        }
        if folders[path] == nil {
            let listFolder = listFolder
            folders[path] = (Task.detached(priority: .utility) { await listFolder(path) },
                             rotation.nextTurn(after: now(), calendar: calendar()), nil)
        }
        guard let request = folders[path] else { return }
        // Freshness belongs to the read, not to whichever display eventually consumes it.
        // A shorter cadence also shortens the lifetime of an already cached/in-flight read.
        folders[path]?.expires = min(request.expires, rotation.nextTurn(after: now(), calendar: calendar()))
        if let pictures = request.pictures {
            applyFolder(pictures, rotation: rotation)
            return
        }
        let requestedGeneration = generation
        displayScope.pinBackdrop(.none)
        folderRefresh = Task { [weak self] in
            let pictures = await request.task.value
            guard !Task.isCancelled, let self, !self.stopped, self.generation == requestedGeneration else { return }
            guard let expires = self.folders[path]?.expires, expires > self.now() else {
                self.folders.removeValue(forKey: path)
                self.generation += 1
                self.refreshFolder(path, rotation: rotation)
                return
            }
            self.folders[path]?.pictures = pictures
            self.applyFolder(pictures, rotation: rotation)
        }
    }

    private func applyFolder(_ pictures: [BackdropSelection], rotation: BackdropRotation) {
        let date = now(), calendar = calendar()
        let picture = rotation.index(count: pictures.count, on: date, calendar: calendar).map { pictures[$0] }
        displayScope.pinBackdrop(picture.map(BackdropPin.selection) ?? .none)
        schedule(after: max(1, rotation.nextTurn(after: date, calendar: calendar).timeIntervalSince(date) + 1))
    }

    private func schedule(after wait: TimeInterval) {
        timer.schedule(after: .seconds(wait)) { @MainActor [weak self] in self?.refresh() }
    }
}
