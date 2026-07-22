import AppKit

@MainActor
final class ViewerNavigationKeyRouter {
    private let actions: [KeyboardShortcutSettings.Action]
    private var bindings: [(action: KeyboardShortcutSettings.Action, shortcut: StoredShortcut)] = []
    private var settingsObserver: NSObjectProtocol?
    private var pendingChord: (prefix: ShortcutStroke, expiresAt: TimeInterval)?
    private static let chordTimeout: TimeInterval = 0.7

    init(actions: [KeyboardShortcutSettings.Action]) {
        self.actions = actions
        reloadBindings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadBindings()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func reset() {
        pendingChord = nil
    }

    func handle(
        _ event: NSEvent,
        isAllowed: (KeyboardShortcutSettings.Action, NSEvent) -> Bool,
        perform: (KeyboardShortcutSettings.Action) -> Void
    ) -> Bool {
        if let pendingChord {
            self.pendingChord = nil
            if event.timestamp <= pendingChord.expiresAt {
                for (action, shortcut) in bindings {
                    guard shortcut.firstStroke == pendingChord.prefix,
                          let secondStroke = shortcut.secondStroke,
                          secondStroke.matches(event: event),
                          isAllowed(action, event) else { continue }
                    perform(action)
                    return true
                }
            }
        }

        for (action, shortcut) in bindings where !shortcut.isUnbound {
            guard isAllowed(action, event) else { continue }
            if shortcut.secondStroke != nil {
                if shortcut.firstStroke.matches(event: event) {
                    pendingChord = (
                        prefix: shortcut.firstStroke,
                        expiresAt: event.timestamp + Self.chordTimeout
                    )
                    return true
                }
            } else if shortcut.matches(event: event) {
                perform(action)
                return true
            }
        }
        return false
    }

    private func reloadBindings() {
        bindings = actions.map { action in
            (action, KeyboardShortcutSettings.shortcut(for: action))
        }
        reset()
    }
}
