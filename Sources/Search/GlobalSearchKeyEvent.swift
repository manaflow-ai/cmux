import AppKit

struct GlobalSearchKeyEvent: Sendable {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    private let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        modifierFlagsRawValue = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    func hasExactModifiers(_ expected: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.subtracting(.capsLock) == expected
    }
}
