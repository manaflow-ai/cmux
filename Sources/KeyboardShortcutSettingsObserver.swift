import Combine
import Foundation

/// Publishes keyboard-shortcut revisions and owns the right-sidebar matcher snapshot.
@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0
    let rightSidebarModeShortcutMatcher = RightSidebarModeShortcutMatcher()
    private var settingsCancellable: AnyCancellable?
    private var recorderCancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        settingsCancellable = notificationCenter.publisher(
            for: KeyboardShortcutSettings.didChangeNotification
        ).sink { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.revision &+= 1
                self?.rightSidebarModeShortcutMatcher.reload()
            }
        }
        recorderCancellable = notificationCenter.publisher(
            for: KeyboardShortcutRecorderActivity.didChangeNotification
        ).sink { [weak self] _ in
            Self.deliverOnMainActor { [weak self] in
                self?.revision &+= 1
            }
        }
    }

    /// Preserves synchronous delivery for main-thread settings mutations while
    /// bridging background file-watcher notifications onto the main actor.
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
