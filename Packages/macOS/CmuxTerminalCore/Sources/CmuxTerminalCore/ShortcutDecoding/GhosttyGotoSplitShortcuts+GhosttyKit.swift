public import GhosttyKit

extension GhosttyGotoSplitShortcuts {
    /// Decodes the four directional `goto_split` shortcuts from a GhosttyKit
    /// config, or yields ``GhosttyGotoSplitShortcuts/none`` when there is no
    /// config.
    ///
    /// This is the whole-cluster lift of `AppDelegate.refreshGhosttyGotoSplitShortcuts`:
    /// for each ``Direction`` it reads the binding via `ghostty_config_trigger`
    /// (using ``Direction/ghosttyActionKey``), lifts the C trigger into a
    /// ``GhosttyTriggerInput`` (``GhosttyTriggerInput/init(decoding:)``), and
    /// decodes that into a ``GhosttyTriggerShortcut`` (``GhosttyTriggerShortcut/init(decoding:)``),
    /// exactly the chain the old per-direction `storedShortcutFromGhosttyTrigger`
    /// ran before assembling a `StoredShortcut`. A `nil` config maps every
    /// direction to `nil`, matching the builder's `config == nil` early-return.
    ///
    /// CmuxTerminalCore re-vends the GhosttyKit binary target, so the C symbols
    /// are visible here. The app target passes `GhosttyApp.shared.config` and then
    /// maps each decoded direction onto its own `StoredShortcut` and runs the
    /// `NSEvent` matching at the call seam.
    /// - Parameter config: The resolved GhosttyKit config, or `nil`.
    public init(decodingConfig config: ghostty_config_t?) {
        guard let config else {
            self = .none
            return
        }

        func decode(_ direction: Direction) -> GhosttyTriggerShortcut? {
            let key = direction.ghosttyActionKey
            let trigger = ghostty_config_trigger(config, key, UInt(key.utf8.count))
            guard
                let input = GhosttyTriggerInput(decoding: trigger),
                let shortcut = GhosttyTriggerShortcut(decoding: input)
            else { return nil }
            return shortcut
        }

        self.init(
            left: decode(.left),
            right: decode(.right),
            up: decode(.up),
            down: decode(.down)
        )
    }
}
