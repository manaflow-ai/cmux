import Carbon
import CmuxSettings
import Foundation
import Observation

/// Observes keyboard-shortcut revisions and owns hot-path matcher snapshots.
@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut
    typealias ExplicitShortcutProvider =
        (KeyboardShortcutSettings.Action) -> StoredShortcut?
    typealias WhenClauseProvider =
        (KeyboardShortcutSettings.Action) -> ShortcutWhenClause

    struct ShortcutBinding: Equatable {
        let action: KeyboardShortcutSettings.Action
        let shortcut: StoredShortcut
        let whenClause: ShortcutWhenClause
    }

    static let shared = KeyboardShortcutSettingsObserver()

    private(set) var revision: UInt64 = 0
    private(set) var globalSearchShortcut: StoredShortcut
    private(set) var configuredChordBindings: [ShortcutBinding]
    private(set) var applicationPaneExplicitShortcutBindings: [ShortcutBinding]
    let rightSidebarModeShortcutMatcher: RightSidebarModeShortcutMatcher
    private let notificationCenter: NotificationCenter
    private let distributedNotificationCenter: DistributedNotificationCenter
    @ObservationIgnored
    private let shortcutProvider: ShortcutProvider
    @ObservationIgnored
    private let explicitShortcutProvider: ExplicitShortcutProvider
    @ObservationIgnored
    private let whenClauseProvider: WhenClauseProvider
    @ObservationIgnored
    private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored
    private var recorderObserver: NSObjectProtocol?
    @ObservationIgnored
    private var inputSourceObserver: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        distributedNotificationCenter: DistributedNotificationCenter = .default(),
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:),
        explicitShortcutProvider: @escaping ExplicitShortcutProvider =
            KeyboardShortcutSettings.explicitlyConfiguredShortcutIfBound(for:),
        whenClauseProvider: @escaping WhenClauseProvider =
            KeyboardShortcutSettings.effectiveWhenClause(for:)
    ) {
        self.notificationCenter = notificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.shortcutProvider = shortcutProvider
        self.explicitShortcutProvider = explicitShortcutProvider
        self.whenClauseProvider = whenClauseProvider
        globalSearchShortcut = shortcutProvider(.globalSearch)
        configuredChordBindings = Self.makeConfiguredChordBindings(
            shortcutProvider: shortcutProvider,
            whenClauseProvider: whenClauseProvider
        )
        applicationPaneExplicitShortcutBindings =
            Self.makeApplicationPaneExplicitShortcutBindings(
                explicitShortcutProvider: explicitShortcutProvider,
                whenClauseProvider: whenClauseProvider
            )
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
        configuredChordBindings = Self.makeConfiguredChordBindings(
            shortcutProvider: shortcutProvider,
            whenClauseProvider: whenClauseProvider
        )
        applicationPaneExplicitShortcutBindings =
            Self.makeApplicationPaneExplicitShortcutBindings(
                explicitShortcutProvider: explicitShortcutProvider,
                whenClauseProvider: whenClauseProvider
            )
        revision &+= 1
        rightSidebarModeShortcutMatcher.reload()
    }

    private static func makeConfiguredChordBindings(
        shortcutProvider: ShortcutProvider,
        whenClauseProvider: WhenClauseProvider
    ) -> [ShortcutBinding] {
        KeyboardShortcutSettings.Action.allCases.compactMap { action in
            guard
                !action.isSystemWideHotkey,
                action != .globalSearch,
                action.allowsChordShortcut,
                !action.isBrowserContentShortcut
            else {
                return nil
            }
            let shortcut = shortcutProvider(action)
            guard shortcut.hasChord else { return nil }
            return ShortcutBinding(
                action: action,
                shortcut: shortcut,
                whenClause: whenClauseProvider(action)
            )
        }
    }

    private static func makeApplicationPaneExplicitShortcutBindings(
        explicitShortcutProvider: ExplicitShortcutProvider,
        whenClauseProvider: WhenClauseProvider
    ) -> [ShortcutBinding] {
        KeyboardShortcutSettings.Action.allCases.compactMap { action in
            guard
                !action.isSystemWideHotkey,
                let shortcut = explicitShortcutProvider(action),
                !shortcut.hasChord
            else {
                return nil
            }
            return ShortcutBinding(
                action: action,
                shortcut: shortcut,
                whenClause: whenClauseProvider(action)
            )
        }
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
