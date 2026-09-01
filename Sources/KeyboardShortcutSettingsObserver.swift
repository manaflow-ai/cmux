import Carbon
import CmuxSettings
import Foundation
import Observation

/// Whether a persisted shortcut key token represents a non-printable AppKit
/// key. Shared by the browser-capture candidate index and event fast path so
/// function/navigation keys cannot drift into an incomplete literal list.
func cmuxShortcutKeyIsNonPrintable(_ key: String) -> Bool {
    let normalizedKey = key.lowercased()
    if normalizedKey == "space" || normalizedKey == "\t" || normalizedKey == "\r" {
        return true
    }
    if ["←", "→", "↑", "↓"].contains(normalizedKey) {
        return true
    }
    guard normalizedKey.first == "f",
          let functionNumber = Int(normalizedKey.dropFirst()) else {
        return false
    }
    return (1...20).contains(functionNumber)
}

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
        settingsOwner: () -> AnyObject?,
        configOwner: () -> AnyObject?,
        configOwnerPresent: Bool,
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
    // A fixed-size ring keeps one snapshot per recently used window/config
    // without retaining an unbounded set of per-window entries.
    private var browserCaptureMatcherSnapshotCache: [BrowserCaptureMatcherSnapshot] = []
    @ObservationIgnored
    private var browserCaptureMatcherCacheNextIndex = 0

    private static let browserCaptureMatcherCacheCapacity = 4

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
                self?.invalidateBrowserCaptureMatcherSnapshots()
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
        invalidateBrowserCaptureMatcherSnapshots()
    }

    private func invalidateBrowserCaptureMatcherSnapshots() {
        browserCaptureMatcherSnapshotCache.removeAll(keepingCapacity: true)
        browserCaptureMatcherCacheNextIndex = 0
    }

    /// Returns the browser-capture matcher snapshot for the current shortcut
    /// and config revisions. The configured-shortcut provider is evaluated only
    /// on a bounded-cache miss, keeping command events out of the config
    /// filtering/sorting path. Stale-default menu eligibility is intentionally
    /// left to the caller at match time because menu state is independent.
    func browserCaptureMatcherSnapshot(
        settingsOwner: AnyObject,
        configOwner: AnyObject?,
        configRevision: UInt64?,
        configuredShortcuts: () -> [StoredShortcut]
    ) -> BrowserCaptureMatcherSnapshot {
        if let snapshot = browserCaptureMatcherSnapshotCache.first(where: { snapshot in
            snapshot.settingsRevision == revision
                && snapshot.settingsOwner() === settingsOwner
                && snapshot.configOwnerPresent == (configOwner != nil)
                && snapshot.configOwner() === configOwner
                && snapshot.configRevision == configRevision
        }) {
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
            let isUnmodifiedSpecialKey = flags.isEmpty
                && cmuxShortcutKeyIsNonPrintable(stroke.key)
            guard isBareSpace || isShiftOrOption || isUnmodifiedSpecialKey else { return }
            candidateStrokes.insert(stroke)
        }

        for action in KeyboardShortcutSettings.Action.allCases {
            guard !action.isBrowserContentShortcut,
                  !action.isProtectedFromBrowserCapture else {
                continue
            }
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
               !defaultShortcut.isUnbound {
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
            settingsOwner: { [weak settingsOwner] in settingsOwner },
            configOwner: { [weak configOwner] in configOwner },
            configOwnerPresent: configOwner != nil,
            configRevision: configRevision,
            actions: actions,
            configuredShortcuts: configured,
            staleDefaults: staleDefaults,
            candidateStrokes: candidateStrokes
        )
        if browserCaptureMatcherSnapshotCache.count < Self.browserCaptureMatcherCacheCapacity {
            browserCaptureMatcherSnapshotCache.append(snapshot)
        } else {
            browserCaptureMatcherSnapshotCache[browserCaptureMatcherCacheNextIndex] = snapshot
            browserCaptureMatcherCacheNextIndex =
                (browserCaptureMatcherCacheNextIndex + 1) % Self.browserCaptureMatcherCacheCapacity
        }
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
