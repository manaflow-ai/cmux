import Carbon
import CmuxFoundation
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
    private let defaults: UserDefaults
    @ObservationIgnored
    private var visibleRightSidebarModes: [RightSidebarMode]
    @ObservationIgnored
    private var sidebarDefaultsObserver: NSObjectProtocol?
    @ObservationIgnored
    private let shortcutProvider: ShortcutProvider
    @ObservationIgnored
    private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored
    private var featureGateObservers: [NSObjectProtocol] = []
    @ObservationIgnored
    private var recorderObserver: NSObjectProtocol?
    @ObservationIgnored
    private var inputSourceObserver: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        distributedNotificationCenter: DistributedNotificationCenter = .default(),
        defaults: UserDefaults = .standard,
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:)
    ) {
        self.notificationCenter = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.defaults = defaults
        visibleRightSidebarModes = RightSidebarMode.visibleModes(defaults: defaults)
        self.shortcutProvider = shortcutProvider
        globalSearchShortcut = shortcutProvider(.globalSearch)
        rightSidebarModeShortcutMatcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: shortcutProvider,
            availability: { $0.isAvailable(defaults: defaults) }
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
        // Policy and rollout changes need not write local defaults, but they
        // still change the positional bindings of the remaining visible tabs.
        featureGateObservers = RightSidebarMode.availabilityChangeNotifications.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Self.deliverOnMainActor { [weak self] in
                    self?.reloadCachedShortcuts()
                }
            }
        }
        // A custom name or beta toggle changes positional defaults even when
        // the sidebar is not mounted. Ignore unrelated preference writes.
        sidebarDefaultsObserver = notificationCenter.addUserDefaultsObserver { [weak self] in
            guard let self,
                  RightSidebarMode.visibleModes(defaults: self.defaults) != self.visibleRightSidebarModes else { return }
            self.reloadCachedShortcuts()
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
        if let sidebarDefaultsObserver {
            notificationCenter.removeObserver(sidebarDefaultsObserver)
        }
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
        }
        for observer in featureGateObservers {
            notificationCenter.removeObserver(observer)
        }
        if let recorderObserver {
            notificationCenter.removeObserver(recorderObserver)
        }
        if let inputSourceObserver {
            distributedNotificationCenter.removeObserver(inputSourceObserver)
        }
    }

    private func reloadCachedShortcuts() {
        visibleRightSidebarModes = RightSidebarMode.visibleModes(defaults: defaults)
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
