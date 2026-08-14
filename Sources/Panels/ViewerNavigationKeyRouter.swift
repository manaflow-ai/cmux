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

    /// Executes an already-resolved action from the global prefix layer.
    ///
    /// The global monitor consumed the first stroke before WebKit could see it,
    /// so the local two-stroke state machine cannot reconstruct the chord. The
    /// action/allowance checks remain here to preserve the viewer's focus and
    /// editability rules while avoiding a second event match.
    @discardableResult
    func performResolved(
        _ action: KeyboardShortcutSettings.Action,
        event: NSEvent,
        isAllowed: (KeyboardShortcutSettings.Action, NSEvent) -> Bool,
        perform: (KeyboardShortcutSettings.Action) -> Void
    ) -> Bool {
        pendingChord = nil
        guard bindings.contains(where: { $0.action == action }),
              isAllowed(action, event) else {
            return false
        }
        perform(action)
        return true
    }

    func handle(
        _ event: NSEvent,
        isAllowed: (KeyboardShortcutSettings.Action, NSEvent) -> Bool,
        perform: (KeyboardShortcutSettings.Action) -> Void
    ) -> Bool {
        if AppDelegate.shared?.shouldBypassPrefixChordPassThrough(event) == true {
            pendingChord = nil
            return false
        }
        if let pendingChord {
            self.pendingChord = nil
            if event.timestamp <= pendingChord.expiresAt {
                for (action, shortcut) in bindings {
                    guard shortcut.firstStroke.isRoutingEquivalent(to: pendingChord.prefix),
                          let secondStroke = shortcut.secondStroke,
                          (AppDelegate.shared?.matchShortcutStroke(event: event, stroke: secondStroke)
                              ?? secondStroke.matches(event: event)),
                          isAllowed(action, event) else { continue }
                    perform(action)
                    return true
                }
            }
        }

        for (action, shortcut) in bindings where !shortcut.isUnbound {
            guard isAllowed(action, event) else { continue }
            if shortcut.secondStroke != nil {
                if (AppDelegate.shared?.matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
                    ?? shortcut.firstStroke.matches(event: event)) {
                    pendingChord = (
                        prefix: shortcut.firstStroke,
                        expiresAt: event.timestamp + Self.chordTimeout
                    )
                    return true
                }
            } else if AppDelegate.shared?.matchConfiguredShortcut(event: event, action: action) == true
                || (AppDelegate.shared == nil && shortcut.matches(event: event)) {
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
