import AppKit

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        modeShortcut(for: event, allowingAction: { _ in true })
    }

    static func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        for mode in RightSidebarMode.allCases {
            guard let action = mode.shortcutAction,
                  allowingAction(action),
                  mode.isAvailable() else {
                continue
            }
            let matches = AppDelegate.shared?.matchConfiguredShortcut(event: event, action: action)
                ?? KeyboardShortcutSettings.shortcut(for: action).matches(event: event)
            guard matches else { continue }
            return mode
        }
        return nil
    }
}
