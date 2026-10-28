public import AppKit
public import Carbon.HIToolbox

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
    private let readTyped: () -> Set<String>
    private var characters: [UInt16: String]?
    private var typed: Set<String>?
    private var observer: KeyboardLayoutObserver?

    /// The live reader: the current ASCII-capable layout, and what the selected layout types.
    public convenience init() {
        self.init(read: Self.readASCIICapableLayout, readTyped: Self.readSelectedLayoutCharacters)
    }

    /// `read` builds the ASCII-capable table, `readTyped` the selected layout's unshifted characters
    /// (tests pass fixtures).
    public init(read: @escaping () -> [UInt16: String], readTyped: @escaping () -> Set<String> = { [] }) {
        self.read = read
        self.readTyped = readTyped
    }

    /// Whether the selected layout types `character` on some key with no modifier (Dvorak types `[`,
    /// German does not: it is Option-5 there).
    public func typesUnshifted(_ character: String) -> Bool {
        if let typed { return typed.contains(character) }
        let built = readTyped()
        typed = built
        observeLayoutChanges()
        return built.contains(character)
    }

    private func observeLayoutChanges() {
        guard observer == nil else { return }
        // Later layouts are read when they are selected, not on the next key.
        observer = KeyboardLayoutObserver { [weak self] in
            guard let self else { return }
            if characters != nil { characters = read() }
            if typed != nil { typed = readTyped() }
        }
    }

    /// What `keyCode` types with `modifiers` on the selected keyboard layout, from `deadKeyState`
    /// (the dead key typed before it; updated), as the layout itself translates it (`UCKeyTranslate`,
    /// dead keys on). Nil when the selected source is an input method, not a keyboard layout: its
    /// text exists only in its engine. Called only for type-ahead keys (a page that is not ready).
    public static func translateOnSelectedLayout(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                                 deadKeyState: inout UInt32) -> String? {
        // SAFETY: a Copy function returns a +1 reference (Create rule), taken over once here.
        guard let selected = unsafe TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              // SAFETY: a Get-rule CFString property owned by `selected`, alive for this call.
              let type = unsafe TISGetInputSourceProperty(selected, kTISPropertyInputSourceType),
              // SAFETY: as above.
              CFEqual(unsafe Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue(), kTISTypeKeyboardLayout),
              // SAFETY: the layout data property is a CFData owned by `selected` (Get rule), alive for this call.
              let pointer = unsafe TISGetInputSourceProperty(selected, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        // SAFETY: as above.
        let data = unsafe Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        // SAFETY: as above.
        guard let bytes = unsafe CFDataGetBytePtr(data) else { return nil }
        // SAFETY: as above; HIToolbox documents the bytes as a UCKeyboardLayout.
        let layout = unsafe UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var state = 0
        if modifiers.contains(.shift) { state |= shiftKey }
        if modifiers.contains(.option) { state |= optionKey }
        if modifiers.contains(.control) { state |= controlKey }
        if modifiers.contains(.command) { state |= cmdKey }
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        // SAFETY: `layout` is valid for this call; UCKeyTranslate writes at most chars.count units
        // into `chars`, one count into `length` and the new state into `deadKeyState`.
        let status = unsafe UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), UInt32(state >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                           0, &deadKeyState, chars.count, &length, &chars)
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// The selected keyboard layout's unshifted characters (`TISCopyCurrentKeyboardLayoutInputSource`:
    /// with an input method selected, the layout it types through).
    nonisolated static func readSelectedLayoutCharacters() -> Set<String> {
        // SAFETY: a Copy function returns a +1 reference (Create rule), taken over once here.
        guard let source = unsafe TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return [] }
        return Set(characters(of: source, asciiOnly: false, command: false).values)
    }

    /// The ASCII-capable layout's character on `keyCode`, or nil (a key that types none there).
    public func asciiCharacter(forKeyCode keyCode: UInt16) -> String? {
        if let characters { return characters[keyCode] }
        let built = read()
        characters = built
        observeLayoutChanges()
        return built[keyCode]
    }

    /// The current ASCII-capable keyboard layout (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`,
    /// the last ASCII layout the person used, US ABC on a new Mac) for every main-block key.
    nonisolated static func readASCIICapableLayout() -> [UInt16: String] {
        // SAFETY: a Copy function returns a +1 reference (Create rule), taken over once here.
        guard let source = unsafe TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return [:] }
        return characters(of: source, asciiOnly: true, command: false)
    }

    /// What each key of `source` (virtual key codes 0-127 but the keypad) types with no modifier
    /// (`command`: with Command alone, the layout's Command key map) and no dead-key state, when
    /// that is one printable character (`asciiOnly`: one printable ASCII character), lowercase. The
    /// one reading of a layout's keys (`KeyCodeLayout` uses it too).
    public nonisolated static func characters(of source: TISInputSource, asciiOnly: Bool, command: Bool) -> [UInt16: String] {
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
        // UCKeyTranslate's modifier state: Carbon's EventModifiers >> 8 (cmdKey is 1 << 8).
        let modifierState: UInt32 = command ? UInt32(cmdKey >> 8) : 0
        for keyCode in UInt16(0)..<128 where !(kVK_ANSI_KeypadDecimal...kVK_ANSI_Keypad9).contains(Int(keyCode)) {
            var deadKeyState: UInt32 = 0
            var length = 0
            // SAFETY: `layout` is valid for this call (above); UCKeyTranslate writes at most
            // chars.count (the max passed) units into `chars` and one count into `length`.
            let status = unsafe UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                                               OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length == 1, chars[0] > 0x20, chars[0] != 0x7F, chars[0] < limit else { continue }
            map[keyCode] = String(utf16CodeUnits: chars, count: length).lowercased()
        }
        return map
    }
}
