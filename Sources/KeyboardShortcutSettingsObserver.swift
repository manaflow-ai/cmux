import Carbon
import Combine
import CmuxSettings
import Foundation

/// Publishes keyboard-shortcut revisions and owns hot-path matcher snapshots.
@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut

    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0
    private(set) var globalSearchShortcut: StoredShortcut
    let rightSidebarModeShortcutMatcher: RightSidebarModeShortcutMatcher
    private let shortcutProvider: ShortcutProvider
    private var settingsCancellable: AnyCancellable?
    private var recorderCancellable: AnyCancellable?
    private var inputSourceCancellable: AnyCancellable?

    init(
        notificationCenter: NotificationCenter = .default,
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:)
    ) {
        self.shortcutProvider = shortcutProvider
        globalSearchShortcut = shortcutProvider(.globalSearch)
        rightSidebarModeShortcutMatcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: shortcutProvider
        )
        settingsCancellable = notificationCenter.publisher(
            for: KeyboardShortcutSettings.didChangeNotification
        ).sink { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.reloadCachedShortcuts()
            }
        }
        recorderCancellable = notificationCenter.publisher(
            for: KeyboardShortcutRecorderActivity.didChangeNotification
        ).sink { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.revision &+= 1
            }
        }
        inputSourceCancellable = DistributedNotificationCenter.default()
            .publisher(
                for: Notification.Name(
                    rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
                )
            )
            .sink { [weak self] _ in
                Self.deliverOnMainActor { [weak self] in
                    self?.reloadCachedShortcuts()
                }
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
