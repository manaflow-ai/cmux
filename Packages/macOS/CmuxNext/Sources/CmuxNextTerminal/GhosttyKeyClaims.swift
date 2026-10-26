public import AppKit
import GhosttyNextKit

/// One key cmux has a default binding on, as Ghostty's binding set sees a
/// key-down: the Mac virtual key code, the unshifted codepoint (0 for keys
/// that type nothing, like arrows) and the Shift/Control/Option/Command mods.
public nonisolated struct GhosttyKeyProbe: Sendable, Equatable {
    public var keyCode: UInt16
    public var unshifted: UInt32
    public var modifiers: NSEvent.ModifierFlags

    public init(keyCode: UInt16, unshifted: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.unshifted = unshifted
        self.modifiers = modifiers.intersection([.shift, .control, .option, .command])
    }
}

/// Keys the user's Ghostty config claims for itself (PANE-FOCUS-RESIZE-KEYS-
/// AND-GHOSTTY-KEYBINDS): a `keybind` line that maps the key to an action
/// (a terminal action like `text:` or `csi:`, or any other), or `unbind`s
/// it. Such a line wins over a cmux default on that key; cmux.json still
/// wins over it.
///
/// Read from Ghostty's own binding set (`ghostty_config_key_is_binding`):
/// a key is claimed when the loaded config and a config without the user's
/// files (Ghostty's and cmux's defaults) disagree on whether it is bound.
/// An `unbind` of a key Ghostty never bound leaves its set unchanged, so
/// those lines are read from the loaded files and their triggers parsed by
/// Ghostty (as `ignore` binds in a scratch config). Nothing is copied into
/// cmux.json or cmux settings.
///
/// Limit: a user line that rebinds one of Ghostty's default keys to another
/// non-routed action is not seen (bound in both configs); Ghostty's API has
/// no forward key-to-action map.
struct GhosttyKeyClaims {
    /// For each probe, whether `user` (the loaded config) claims it, given
    /// `defaults` (no user files) and `unbinds` (the user's `unbind` lines).
    /// The three configs are live handles the caller holds for the call.
    static func claimed(_ probes: [GhosttyKeyProbe], user: ghostty_config_t, defaults: ghostty_config_t,
                        unbinds: ghostty_config_t?) -> [Bool] {
        probes.map { probe in
            let key = keyEvent(probe)
            // SAFETY: the caller's live configs; `key` carries no text pointer (keyEvent).
            let bound = unsafe ghostty_config_key_is_binding(user, key)
            // SAFETY: as above.
            if unsafe bound != ghostty_config_key_is_binding(defaults, key) { return true }
            // SAFETY: as above.
            guard !bound, let unbinds = unsafe unbinds else { return false }
            // SAFETY: as above.
            return unsafe ghostty_config_key_is_binding(unbinds, key)
        }
    }

    static func keyEvent(_ probe: GhosttyKeyProbe) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GhosttyInput.mods(probe.modifiers)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(probe.keyCode)
        // SAFETY: a null text pointer: a probe has no text.
        unsafe key.text = nil
        key.unshifted_codepoint = probe.unshifted
        key.composing = false
        return key
    }

    /// The triggers of `keybind = <trigger>=unbind` lines in config text.
    /// Sequences (`a>b`) and `catch_all` are left out: one key-down is never
    /// their whole trigger.
    static func unbindTriggers(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("keybind"), let equals = line.firstIndex(of: "=") else { return nil }
            guard line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces) == "keybind" else { return nil }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard let last = value.range(of: "=", options: .backwards) else { return nil }
            guard value[last.upperBound...].trimmingCharacters(in: .whitespaces) == "unbind" else { return nil }
            let trigger = value[..<last.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, !trigger.contains(">"), !trigger.contains("catch_all") else { return nil }
            return trigger
        }
    }

    /// A finalized scratch config binding each trigger to `ignore` (Ghostty
    /// parses the trigger), or nil when there is none. The caller frees it.
    static func unbindConfig(triggers: [String]) -> ghostty_config_t? {
        // SAFETY: a new config, live until the caller frees it; this function only fills it.
        guard !triggers.isEmpty, let config = unsafe ghostty_config_new() else { return nil }
        for trigger in triggers {
            // SAFETY: as above.
            unsafe GhosttyRuntime.loadConfigLine("keybind = \(trigger)=ignore", into: config, source: "cmux-next")
        }
        // SAFETY: as above.
        unsafe ghostty_config_finalize(config)
        // SAFETY: as above; the caller takes it over.
        return unsafe config
    }

    /// A finalized config without the user's files: Ghostty's defaults with
    /// cmux's over them. The caller frees it.
    static func defaultsConfig() -> ghostty_config_t? {
        // SAFETY: a new config, live until the caller frees it; this function only fills it.
        guard let config = unsafe ghostty_config_new() else { return nil }
        // SAFETY: as above.
        unsafe GhosttyRuntime.loadKeybindDefaults(into: config)
        // SAFETY: as above.
        unsafe ghostty_config_finalize(config)
        // SAFETY: as above; the caller takes it over.
        return unsafe config
    }

    /// For each probe, whether `user` claims it, its `unbind` lines read from
    /// `texts` (the loaded files' contents).
    /// `user` is a live handle the caller holds for the call.
    static func claimed(_ probes: [GhosttyKeyProbe], user: ghostty_config_t, texts: [String]) -> [Bool] {
        // SAFETY: two configs this function takes over from their makers and frees once each
        // (defer), after their last use; `user` is the caller's live config.
        guard let defaults = unsafe defaultsConfig() else { return probes.map { _ in false } }
        // SAFETY: as above.
        defer { unsafe ghostty_config_free(defaults) }
        // SAFETY: as above.
        let unbinds = unsafe unbindConfig(triggers: texts.flatMap(unbindTriggers(in:)))
        // SAFETY: as above.
        defer { if let unbinds = unsafe unbinds { unsafe ghostty_config_free(unbinds) } }
        // SAFETY: as above.
        return unsafe claimed(probes, user: user, defaults: defaults, unbinds: unbinds)
    }

    /// For each probe, whether a config made of `text` claims it (tests).
    static func claimed(_ probes: [GhosttyKeyProbe], configText text: String) -> [Bool] {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        let claims = unsafe GhosttyRuntime.withScratchConfig(load: {
            // SAFETY: as above.
            unsafe GhosttyRuntime.loadKeybindDefaults(into: $0)
            // SAFETY: as above.
            unsafe GhosttyRuntime.loadConfigLine(text, into: $0, source: "test")
        }, read: {
            // SAFETY: as above.
            unsafe claimed(probes, user: $0, texts: [text])
        })
        return claims ?? probes.map { _ in false }
    }
}

extension GhosttyRuntime {
    /// For each probe, whether the loaded config claims it (a keybind or
    /// `unbind` in the user's files), the `unbind` lines read from `texts`
    /// (``configTexts(_:)`` of ``loadedConfigFiles``). All false without a
    /// config.
    public func userClaimedKeys(_ probes: [GhosttyKeyProbe], texts: [String]) -> [Bool] {
        guard let config else { return probes.map { _ in false } }
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config).
        return unsafe GhosttyKeyClaims.claimed(probes, user: config, texts: texts)
    }

    /// The contents of config files, read off the main actor (missing or
    /// unreadable files are left out).
    @concurrent public nonisolated static func configTexts(_ paths: [String]) async -> [String] {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }
}
