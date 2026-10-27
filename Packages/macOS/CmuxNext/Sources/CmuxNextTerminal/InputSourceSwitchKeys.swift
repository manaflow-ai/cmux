import AppKit
import Carbon.HIToolbox

// Chromium reads the system hot keys once, off the main thread (content/browser/cocoa/system_hotkey_helper_mac.mm),
// into a map it looks keys up in (content/browser/cocoa/system_hotkey_map.mm), never per key event.

/// The keys that switch the input source system-wide: Select the previous input source and Select next
/// source in Input menu (`com.apple.symbolichotkeys` 60 and 61, by default Ctrl-Space and Ctrl-Option-Space),
/// and the Globe key when it is set to Change Input Source (`com.apple.HIToolbox` `AppleFnUsageType` 1).
///
/// ```swift
/// let keys = InputSourceSwitchKeys(symbolicHotKeys: nil, fnUsageType: nil)
/// keys.matches(keyCode: UInt16(kVK_Space), flags: .control) // true
/// ```
nonisolated struct InputSourceSwitchKeys: Equatable, Sendable {
    /// A physical key and its modifiers (`NSEvent.ModifierFlags` raw bits under ``modifierMask``).
    nonisolated struct HotKey: Hashable, Sendable {
        var keyCode: UInt16
        var modifiers: UInt
    }

    /// The `AppleSymbolicHotKeys` ids and their system defaults, used when the user never changed one.
    static let systemDefaults: [Int: HotKey] = [
        60: HotKey(keyCode: UInt16(kVK_Space), modifiers: NSEvent.ModifierFlags.control.rawValue),
        61: HotKey(keyCode: UInt16(kVK_Space), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
    ]
    /// Shift, Control, Option, Command and Fn: the same bits in the hot key parameters and in
    /// `NSEvent.ModifierFlags`.
    static let modifierMask: UInt = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function]).rawValue
    /// Keys AppKit reports with the Fn flag on their own (arrows, F1-F20, the navigation keys).
    static let functionKeyCodes: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
    ].map { UInt16($0) })

    /// The enabled switch hot keys.
    let hotKeys: Set<HotKey>
    /// The Globe key changes the input source, so a Globe chord may too.
    let globeChangesInputSource: Bool

    init(hotKeys: Set<HotKey>, globeChangesInputSource: Bool) {
        self.hotKeys = hotKeys
        self.globeChangesInputSource = globeChangesInputSource
    }

    /// Parses the `AppleSymbolicHotKeys` dictionary (id string to `{enabled, value: {parameters: [char,
    /// keyCode, modifiers]}}`) and `AppleFnUsageType`. A missing entry or setting counts as the system
    /// default, on: a key wrongly taken for a switch key only costs two input-source reads.
    init(symbolicHotKeys: [String: Any]?, fnUsageType: Int?) {
        var keys = Set<HotKey>()
        for (id, fallback) in Self.systemDefaults {
            guard let entry = symbolicHotKeys?[String(id)] as? [String: Any] else {
                keys.insert(fallback)
                continue
            }
            if let enabled = entry["enabled"], Self.number(enabled) == 0 { continue }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any] ?? []
            guard parameters.count >= 3 else {
                keys.insert(fallback)
                continue
            }
            // 65535: the hot key has no physical key.
            let keyCode = Self.number(parameters[1])
            guard (0..<0xFFFF).contains(keyCode) else { continue }
            keys.insert(HotKey(keyCode: UInt16(keyCode), modifiers: UInt(max(0, Self.number(parameters[2]))) & Self.modifierMask))
        }
        self.init(hotKeys: keys, globeChangesInputSource: (fnUsageType ?? 1) == 1)
    }

    /// Whether a key-down of `keyCode` with `flags` is one of the switch keys.
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if hotKeys.contains(HotKey(keyCode: keyCode, modifiers: flags.rawValue & Self.modifierMask)) { return true }
        return globeChangesInputSource && flags.contains(.function) && !Self.functionKeyCodes.contains(keyCode)
    }

    /// The current user's settings (another app's preferences, read only). A preferences read waits on
    /// cfprefsd: call it off the main thread.
    static func readSystem() -> InputSourceSwitchKeys {
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        let fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return InputSourceSwitchKeys(symbolicHotKeys: hotKeys as? [String: Any], fnUsageType: (fnUsage as? NSNumber)?.intValue)
    }

    private static func number(_ value: Any?) -> Int {
        if let flag = value as? Bool { return flag ? 1 : 0 }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}
