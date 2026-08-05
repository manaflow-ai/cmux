import Foundation
import Observation

/// Observes keyboard-shortcut revisions and owns hot-path matcher snapshots.
@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    typealias ShortcutProvider = @Sendable (KeyboardShortcutSettings.Action) -> StoredShortcut

    static let shared = KeyboardShortcutSettingsObserver()

    private(set) var revision: UInt64 = 0
    private(set) var shortcutSnapshot: KeyboardShortcutSnapshot
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private let shortcutProvider: ShortcutProvider
    @ObservationIgnored
    private var hasStartedPersistenceRefresh = false
    @ObservationIgnored
    private var cachedRightSidebarModeShortcutMatcher: RightSidebarModeShortcutMatcher?
    @ObservationIgnored
    private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored
    private var recorderObserver: NSObjectProtocol?
    @ObservationIgnored
    private var inputSourceObserver: NSObjectProtocol?
    @ObservationIgnored
    private lazy var snapshotCache = GenerationCoalescingSnapshotCache(
        initialSnapshot: shortcutSnapshot,
        loader: { [shortcutProvider] in
            KeyboardShortcutSnapshot.load(using: shortcutProvider)
        },
        installHandler: { [weak self] replacement in
            self?.install(replacement)
        }
    )

    var globalSearchShortcut: StoredShortcut {
        shortcut(for: .globalSearch)
    }

    var rightSidebarModeShortcutMatcher: RightSidebarModeShortcutMatcher {
        if let cachedRightSidebarModeShortcutMatcher {
            return cachedRightSidebarModeShortcutMatcher
        }
        let matcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: { [weak self] action in
                self?.shortcut(for: action) ?? action.defaultShortcut
            }
        )
        cachedRightSidebarModeShortcutMatcher = matcher
        return matcher
    }

    init(
        notificationCenter: NotificationCenter = .default,
        initialSnapshot: KeyboardShortcutSnapshot = .defaults,
        shortcutProvider: @escaping ShortcutProvider = { action in
            KeyboardShortcutSettings.shortcut(for: action)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.shortcutProvider = shortcutProvider
        shortcutSnapshot = initialSnapshot
        settingsObserver = notificationCenter.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.requestShortcutRefresh()
            }
        }
        recorderObserver = notificationCenter.addObserver(
            forName: KeyboardShortcutRecorderActivity.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.revision &+= 1
            }
        }
        inputSourceObserver = notificationCenter.addObserver(
            forName: KeyboardLayout.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.requestShortcutRefresh()
            }
        }
    }

    deinit {
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
        }
        if let recorderObserver {
            notificationCenter.removeObserver(recorderObserver)
        }
        if let inputSourceObserver {
            notificationCenter.removeObserver(inputSourceObserver)
        }
    }

    func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        shortcutSnapshot.shortcut(for: action)
    }

    /// Activates persistence-backed snapshots after the settings store has
    /// completed initialization. Construction stays inert so synchronous
    /// settings notifications cannot create a startup initialization cycle.
    func start() {
        guard !hasStartedPersistenceRefresh else { return }
        hasStartedPersistenceRefresh = true
        snapshotCache.requestRefresh()
    }

    func waitUntilShortcutSnapshotIsIdle() async {
        await snapshotCache.waitUntilIdle()
    }

    private func requestShortcutRefresh() {
        revision &+= 1
        guard hasStartedPersistenceRefresh else { return }
        snapshotCache.requestRefresh()
    }

    private func install(_ replacement: KeyboardShortcutSnapshot) {
        shortcutSnapshot = replacement
        revision &+= 1
        cachedRightSidebarModeShortcutMatcher?.reload()
    }

    /// Preserves synchronous delivery for main-thread settings mutations while
    /// bridging background notifications onto the main actor.
    nonisolated private static func deliverOnMainActor(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                action()
            }
        } else {
            Task { @MainActor in
                action()
            }
        }
    }
}
