import AppKit
import CmuxSettings

@MainActor
final class ViewerNavigationKeyRouter {
    private let actions: [KeyboardShortcutSettings.Action]
    private var bindings: [(action: KeyboardShortcutSettings.Action, binding: ConfiguredShortcutBinding)] = []
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
        bindingIsAllowed: ((KeyboardShortcutSettings.Action, ShortcutWhenClause, NSEvent) -> Bool)? = nil,
        perform: (KeyboardShortcutSettings.Action) -> Void
    ) -> Bool {
        if let pendingChord {
            self.pendingChord = nil
            if event.timestamp <= pendingChord.expiresAt {
                for (action, binding) in bindings {
                    let shortcut = binding.shortcut
                    guard shortcut.firstStroke == pendingChord.prefix,
                          let secondStroke = shortcut.secondStroke,
                          secondStroke.matches(event: event),
                          (bindingIsAllowed?(action, binding.whenClause, event) ?? isAllowed(action, event)) else { continue }
                    perform(action)
                    return true
                }
            }
        }

        for (action, binding) in bindings where !binding.shortcut.isUnbound {
            let shortcut = binding.shortcut
            guard bindingIsAllowed?(action, binding.whenClause, event) ?? isAllowed(action, event) else { continue }
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
        bindings = actions.flatMap { action in
            KeyboardShortcutSettings.shortcutBindings(for: action).map { (action, $0) }
        }
        reset()
    }
}
