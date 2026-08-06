import AppKit

struct KeyboardLayoutSnapshotKey: Hashable, Sendable {
    let keyCode: UInt16
    private let modifierFlagsRawValue: UInt

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }
}
