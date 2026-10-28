public import Carbon.HIToolbox
import Foundation

/// What the ASCII-capable keyboard layout types on each physical key (virtual key codes 0-127,
/// unshifted, lowercase): the last reading of ``KeyInput``'s match, for a Command or Control
/// chord whose key types no ASCII character on the selected layout (Russian, Greek, Hebrew,
/// Arabic, Thai, Kana). This is the key the person sees on the keyboard's Latin legend, and
/// AppKit's and Chrome's fallback for shortcuts on those layouts.
///
/// Read on first use and again at each layout change (`KeyboardLayoutObserver`, off the key
/// path), never per key: a key-down only looks the table up.
///
/// Each ``ActionRegistry`` owns one (``ActionRegistry/keyboardLayout``); the app makes one registry.
public final class KeyboardLayoutKeys {
    private let read: () -> [UInt16: String]
    private var characters: [UInt16: String]?
    private var observer: KeyboardLayoutObserver?

    /// The live reader: the current ASCII-capable layout.
    public convenience init() {
        self.init(read: Self.readASCIICapableLayout)
    }

    /// `read` builds the table (tests pass a fixture).
    public init(read: @escaping () -> [UInt16: String]) {
        self.read = read
    }

    /// The ASCII-capable layout's character on `keyCode`, or nil (a key that types none there).
    public func asciiCharacter(forKeyCode keyCode: UInt16) -> String? {
        if let characters { return characters[keyCode] }
        let built = read()
        characters = built
        // Later layouts are read when they are selected, not on the next key.
        if observer == nil {
            observer = KeyboardLayoutObserver { [weak self] in
                guard let self else { return }
                characters = read()
            }
        }
        return built[keyCode]
    }

    /// The current ASCII-capable keyboard layout (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`,
    /// the last ASCII layout the person used, US ABC on a new Mac) for every main-block key.
    nonisolated static func readASCIICapableLayout() -> [UInt16: String] {
        // SAFETY: a Copy function returns a +1 reference (Create rule), taken over once here.
        guard let source = unsafe TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return [:] }
        return characters(of: source, asciiOnly: true)
    }

    /// What each key of `source` (virtual key codes 0-127 but the keypad) types with no modifier
    /// and no dead-key state, when that is one printable character (`asciiOnly`: one printable
    /// ASCII character), lowercase. The one reading of a layout's keys (`KeyCodeLayout` uses it too).
    public nonisolated static func characters(of source: TISInputSource, asciiOnly: Bool) -> [UInt16: String] {
        // SAFETY: the layout data property is a CFData owned by `source` (Get rule), which the
        // caller holds for this call, so it and its bytes stay alive to the end of it.
        guard let pointer = unsafe TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        // SAFETY: as above.
        let data = unsafe Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        // SAFETY: the bytes of `data`, alive for this call (above); HIToolbox documents them as
        // a UCKeyboardLayout (kTISPropertyUnicodeKeyLayoutData).
        guard let bytes = unsafe CFDataGetBytePtr(data) else { return [:] }
        // SAFETY: as above.
        let layout = unsafe UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var map: [UInt16: String] = [:]
        var chars = [UniChar](repeating: 0, count: 4)
        let limit: UniChar = asciiOnly ? 0x7F : UniChar.max
        for keyCode in UInt16(0)..<128 where !(kVK_ANSI_KeypadDecimal...kVK_ANSI_Keypad9).contains(Int(keyCode)) {
            var deadKeyState: UInt32 = 0
            var length = 0
            // SAFETY: `layout` is valid for this call (above); UCKeyTranslate writes at most
            // chars.count (the max passed) units into `chars` and one count into `length`.
            let status = unsafe UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                               OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length == 1, chars[0] > 0x20, chars[0] != 0x7F, chars[0] < limit else { continue }
            map[keyCode] = String(utf16CodeUnits: chars, count: length).lowercased()
        }
        return map
    }
}
