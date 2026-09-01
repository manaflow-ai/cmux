import Carbon
import CmuxSettings
import Foundation
import Observation

/// Observes keyboard-shortcut revisions and owns hot-path matcher snapshots.
@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut

    /// Shared, revision-keyed inputs for browser shortcut capture. The observer
    /// already owns hot-path shortcut snapshots; keeping this cache here avoids
    /// attaching another mutable registry to the AppDelegate singleton.
    typealias BrowserCaptureMatcherEntry = (
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut,
        whenClause: ShortcutWhenClause
    )
    typealias BrowserCaptureMatcherSnapshot = (
        settingsRevision: UInt64,
        settingsStoreID: ObjectIdentifier,
        configStoreID: ObjectIdentifier?,
        configRevision: UInt64?,
        actions: [BrowserCaptureMatcherEntry],
        configuredShortcuts: [StoredShortcut],
        staleDefaults: [BrowserCaptureMatcherEntry],
        candidateStrokes: Set<ShortcutStroke>
    )

    static let shared = KeyboardShortcutSettingsObserver()

    private(set) var revision: UInt64 = 0
    private(set) var globalSearchShortcut: StoredShortcut
    let rightSidebarModeShortcutMatcher: RightSidebarModeShortcutMatcher
    private let notificationCenter: NotificationCenter
    private let distributedNotificationCenter: DistributedNotificationCenter
    @ObservationIgnored
    private let shortcutProvider: ShortcutProvider
    @ObservationIgnored
    private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored
    private var recorderObserver: NSObjectProtocol?
    @ObservationIgnored
    private var inputSourceObserver: NSObjectProtocol?
    @ObservationIgnored
    private var browserCaptureMatcherSnapshotCache: BrowserCaptureMatcherSnapshot?

    init(
        notificationCenter: NotificationCenter = .default,
        distributedNotificationCenter: DistributedNotificationCenter = .default(),
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:)
    ) {
        self.notificationCenter = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.shortcutProvider = shortcutProvider
        globalSearchShortcut = shortcutProvider(.globalSearch)
        rightSidebarModeShortcutMatcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: shortcutProvider
        )
        settingsObserver = notificationCenter.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.reloadCachedShortcuts()
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
        inputSourceObserver = distributedNotificationCenter.addObserver(
            forName: Notification.Name(
                rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
            ),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.reloadCachedShortcuts()
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
            distributedNotificationCenter.removeObserver(inputSourceObserver)
        }
    }

    private func reloadCachedShortcuts() {
        globalSearchShortcut = shortcutProvider(.globalSearch)
        revision &+= 1
        rightSidebarModeShortcutMatcher.reload()
    }

    /// Returns the browser-capture matcher snapshot for the current shortcut
    /// and config revisions. The configured-shortcut provider is evaluated only
    /// when the revision key changes, keeping command events out of the config
    /// filtering/sorting path.
    func browserCaptureMatcherSnapshot(
        settingsStoreID: ObjectIdentifier,
        configStoreID: ObjectIdentifier?,
        configRevision: UInt64?,
        configuredShortcuts: () -> [StoredShortcut],
        isMenuBacked: (KeyboardShortcutSettings.Action) -> Bool
    ) -> BrowserCaptureMatcherSnapshot {
        if let snapshot = browserCaptureMatcherSnapshotCache,
           snapshot.settingsRevision == revision,
           snapshot.settingsStoreID == settingsStoreID,
           snapshot.configStoreID == configStoreID,
           snapshot.configRevision == configRevision {
            return snapshot
        }

        var actions: [BrowserCaptureMatcherEntry] = []
        var staleDefaults: [BrowserCaptureMatcherEntry] = []
        var candidateStrokes = Set<ShortcutStroke>()

        func appendCandidate(_ shortcut: StoredShortcut?) {
            guard let shortcut, !shortcut.isUnbound else { return }
            let stroke = shortcut.firstStroke
            let flags = stroke.modifierFlags
            let isBareSpace = flags.isEmpty && stroke.key.lowercased() == "space"
            let isShiftOrOption = flags.intersection([.command, .control]).isEmpty
                && !flags.intersection([.shift, .option]).isEmpty
            guard isBareSpace || isShiftOrOption else { return }
            candidateStrokes.insert(stroke)
        }

        for action in KeyboardShortcutSettings.Action.allCases {
            guard !action.isBrowserContentShortcut else { continue }
            let currentShortcut = shortcutProvider(action)
            let whenClause = KeyboardShortcutSettings.effectiveWhenClause(for: action)
            if !currentShortcut.isUnbound {
                actions.append(
                    BrowserCaptureMatcherEntry(
                        action: action,
                        shortcut: currentShortcut,
                        whenClause: whenClause
                    )
                )
                appendCandidate(currentShortcut)
            }

            let defaultShortcut = action.defaultShortcut
            if currentShortcut != defaultShortcut,
               !defaultShortcut.isUnbound,
               isMenuBacked(action) {
                staleDefaults.append(
                    BrowserCaptureMatcherEntry(
                        action: action,
                        shortcut: defaultShortcut,
                        whenClause: whenClause
                    )
                )
                appendCandidate(defaultShortcut)
            }
        }

        let configured = configuredShortcuts()
        for shortcut in configured {
            appendCandidate(shortcut)
        }

        let snapshot = BrowserCaptureMatcherSnapshot(
            settingsRevision: revision,
            settingsStoreID: settingsStoreID,
            configStoreID: configStoreID,
            configRevision: configRevision,
            actions: actions,
            configuredShortcuts: configured,
            staleDefaults: staleDefaults,
            candidateStrokes: candidateStrokes
        )
        browserCaptureMatcherSnapshotCache = snapshot
        return snapshot
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
