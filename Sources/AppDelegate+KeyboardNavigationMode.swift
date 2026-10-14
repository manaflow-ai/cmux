import AppKit

extension AppDelegate {
    func exitKeyboardNavigationMode() {
        guard activeKeyboardNavigationMode != nil else {
            forcedKeyboardNavigationActionForCurrentEvent = nil
            forcedKeyboardNavigationShortcutForCurrentEvent = nil
            return
        }
        let windowNumber = activeKeyboardNavigationMode?.windowNumber
        activeKeyboardNavigationMode = nil
        forcedKeyboardNavigationActionForCurrentEvent = nil
        forcedKeyboardNavigationShortcutForCurrentEvent = nil
        postKeyboardNavigationModeChange(windowNumber: windowNumber)
    }

    private func postKeyboardNavigationModeChange(windowNumber: Int? = nil) {
        var userInfo: [AnyHashable: Any] = [:]
        if let activeKeyboardNavigationMode {
            userInfo["mode"] = activeKeyboardNavigationMode.mode.id
            if let activeWindowNumber = activeKeyboardNavigationMode.windowNumber {
                userInfo["windowNumber"] = activeWindowNumber
            }
        } else if let windowNumber {
            userInfo["windowNumber"] = windowNumber
        }
        NotificationCenter.default.post(
            name: .keyboardNavigationModeDidChange,
            object: self,
            userInfo: userInfo
        )
    }

    /// Routes the current key through a persistent navigation mode. Returning
    /// nil means that no mode owns the event and normal shortcut routing should
    /// continue. An unbound key exits the mode and is then passed through unless
    /// the mode explicitly opts into swallowing it.
    func handleKeyboardNavigationMode(event: NSEvent) -> Bool? {
        guard event.type == .keyDown else { return nil }
        guard NSApp.modalWindow == nil,
              event.window.map({ isMainTerminalWindow($0) }) ?? true else {
            return nil
        }

        let navigationModes = KeyboardShortcutSettings.settingsFileStore.keyboardNavigationModes()
        guard activeKeyboardNavigationMode != nil || !navigationModes.isEmpty else {
            return nil
        }

        let matcher = ConfiguredShortcutMatcher(
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        )
        let windowNumber = configuredShortcutChordWindowNumber(for: event)
        if let activeKeyboardNavigationMode {
            guard activeKeyboardNavigationMode.windowNumber == windowNumber else {
                exitKeyboardNavigationMode()
                return nil
            }

            let normalizedFlags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            if event.isARepeat,
               matcher.matches(event: event, shortcut: activeKeyboardNavigationMode.mode.enterShortcut) {
                return true
            }
            if normalizedFlags.isEmpty,
               event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                exitKeyboardNavigationMode()
                return true
            }

            if let binding = activeKeyboardNavigationMode.mode.binding(
                for: event,
                matcher: matcher
            ) {
                forcedKeyboardNavigationActionForCurrentEvent = binding.action
                forcedKeyboardNavigationShortcutForCurrentEvent = binding.shortcut
                defer {
                    forcedKeyboardNavigationActionForCurrentEvent = nil
                    forcedKeyboardNavigationShortcutForCurrentEvent = nil
                }
                _ = handleCustomShortcut(event: event, allowKeyboardNavigationMode: false)
                return true
            }

            if activeKeyboardNavigationMode.mode.swallowUnboundKeys {
                return true
            }
            exitKeyboardNavigationMode()
            return false
        }

        guard let mode = navigationModes
            .values
            .sorted(by: { $0.id.localizedStandardCompare($1.id) == .orderedAscending })
            .first(where: { matcher.matches(event: event, shortcut: $0.enterShortcut) }) else {
            return nil
        }

        activeKeyboardNavigationMode = ActiveKeyboardNavigationMode(
            mode: mode,
            windowNumber: windowNumber
        )
        postKeyboardNavigationModeChange()
        return true
    }
}
