import Carbon
import Foundation
import Observation

/// Observes keyboard-shortcut revisions and owns hot-path matcher snapshots.
@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut

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
    private var featureGateObserver: NSObjectProtocol?
    @ObservationIgnored
    private var recorderObserver: NSObjectProtocol?
    @ObservationIgnored
    private var inputSourceObserver: NSObjectProtocol?

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
        // Feature-gated sidebar defaults are also stored in UserDefaults. The
        // matcher must rebuild when a gate changes, even when no shortcut was
        // edited.
        featureGateObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
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
        if let featureGateObserver {
            notificationCenter.removeObserver(featureGateObserver)
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
