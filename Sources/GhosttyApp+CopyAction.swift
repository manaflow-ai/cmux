import CmuxTerminalCore

extension GhosttyApp {
    /// Returns the Ghostty action native Copy surfaces should send.
    ///
    /// Ghostty's reverse-trigger API is the source of truth for this lookup;
    /// the app only translates its existing ``StoredShortcut`` value into the
    /// package-owned ``GhosttyTriggerShortcut`` representation at this seam.
    @MainActor
    var configuredCopyToClipboardAction: String {
        let bindings = GhosttyCopyActionResolver.Flavor.allCases.compactMap { flavor in
            storedShortcut(forBindingAction: flavor.bindingAction).map { shortcut in
                GhosttyCopyActionResolver.Binding(
                    flavor: flavor,
                    shortcut: GhosttyTriggerShortcut(
                        key: shortcut.key,
                        command: shortcut.command,
                        shift: shortcut.shift,
                        option: shortcut.option,
                        control: shortcut.control
                    )
                )
            }
        }
        return GhosttyCopyActionResolver().resolve(bindings: bindings)
    }
}
