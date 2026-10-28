import Carbon.HIToolbox

/// What the ASCII-capable keyboard layout types on each physical key (virtual key codes 0-127,
/// unshifted, lowercase): the last reading of ``KeyInput``'s match, for a Command or Control
/// chord whose key types no ASCII character on the selected layout (Russian, Greek, Hebrew,
/// Arabic, Thai, Kana). This is the key the person sees on the keyboard's Latin legend, and
/// AppKit's and Chrome's fallback for shortcuts on those layouts.
///
/// Read on first use after each layout change (`KeyboardLayoutObserver`), never per key; a
/// layout that types ASCII on the key never reads it.
///
/// Each ``ActionRegistry`` owns one (``ActionRegistry/keyboardLayout``); the app makes one registry.
public final class KeyboardLayoutKeys {
    /// The live reader: the current ASCII-capable layout.
    public convenience init() {
        self.init(read: Self.readASCIICapableLayout)
    }

    private let read: () -> [UInt16: String]
    private var characters: [UInt16: String]?
    private var observer: KeyboardLayoutObserver?

    /// `read` builds the table (tests pass a fixture).
    public init(read: @escaping () -> [UInt16: String]) {
        self.read = read
    }

    /// The ASCII-capable layout's character on `keyCode`, or nil (a key that types none there).
    public func asciiCharacter(forKeyCode keyCode: UInt16) -> String? {
        if let characters { return characters[keyCode] }
        let built = read()
        characters = built
        if observer == nil { observer = KeyboardLayoutObserver { [weak self] in self?.characters = nil } }
        return built[keyCode]
    }

    /// The current ASCII-capable keyboard layout (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`,
    /// the last ASCII layout the person used, US ABC on a new Mac) for every main-block key.
    nonisolated static func readASCIICapableLayout() -> [UInt16: String] {
        // SAFETY: a Copy function returns a +1 reference (Create rule), taken over once here.
        guard let source = unsafe TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return [:] }
        return characters(of: source)
    }

    /// What each key of `source` types with no modifier and no dead-key state, when that is one
    /// printable ASCII character.
    nonisolated static func characters(of source: TISInputSource) -> [UInt16: String] {
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
        for keyCode in UInt16(0)..<128 where !(kVK_ANSI_KeypadDecimal...kVK_ANSI_Keypad9).contains(Int(keyCode)) {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            // SAFETY: `layout` is valid for this call (above); UCKeyTranslate writes at most
            // chars.count (the max passed) units into `chars` and one count into `length`.
            let status = unsafe UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                               OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length == 1, chars[0] > 0x20, chars[0] < 0x7F else { continue }
            map[keyCode] = String(utf16CodeUnits: chars, count: length).lowercased()
        }
        return map
    }
}
