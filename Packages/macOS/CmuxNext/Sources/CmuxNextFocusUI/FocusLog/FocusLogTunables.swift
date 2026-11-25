public import CmuxNextDesign

/// Debug Settings > Focus and Scroll: the switch for the focus log (``FocusLog``).
/// English developer text, as every Debug Settings section (plans/cmux-next/debug-settings.md).
public struct FocusLogTunables {
    public init() {}
    /// Off by default. On: every keyboard focus change of every cmux window (first responder,
    /// key window, a page's text input losing focus) is appended with its cause and call stack to
    /// `~/Library/Logs/cmux-next/<tag or release>/focus-log.jsonl`. Turn on in Debug Settings > Focus
    /// and Scroll, or the app socket's `debug.tunables` (`{"action": "set", "key": "diagnostics.focusLog",
    /// "value": true}`); it applies at once, no relaunch. Tunables live in `debug-tunables.json`:
    /// `cmux settings set tunable.…` writes cmux-next.json, which no tunable reads.
    public nonisolated static let enabled = Tunable<Bool>.toggle(
        "diagnostics.focusLog", .focus, "Record focus changes",
        help: "Writes every keyboard focus change (first responder, key window, a page's text field losing focus) with its cause and call stack to ~/Library/Logs/cmux-next/<tag or release>/focus-log.jsonl. Lines with \"suspect\": true are focus moves no click or key asked for. No typed text is recorded.",
        default: false, code: "FocusLogTunables.enabled")

    /// Every tunable of the focus log, for the app's catalog (`TunableCatalog`).
    public nonisolated static var all: [TunableDescriptor] { [enabled.descriptor] }
}
