#if DEBUG
import AppKit
import Carbon
import Foundation

extension KeyboardLayout {
    /// Resolves a layout that is not enabled on the host without putting test
    /// controls on the production input-source loader.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        inputSourceID: String
    ) async -> String? {
        await Task.detached(priority: .utility) {
            KeyboardLayoutDebugInputSource(inputSourceID: inputSourceID)?
                .textInputCharacter(
                    forKeyCode: keyCode,
                    modifierFlags: modifierFlags
                )
        }.value
    }
}

private struct KeyboardLayoutDebugInputSource {
    private let source: TISInputSource

    init?(inputSourceID: String) {
        let filter = [
            kTISPropertyInputSourceID as String: inputSourceID,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
            as? [TISInputSource],
            let source = sources.first else {
            return nil
        }
        self.source = source
    }

    func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        let characters = KeyboardLayoutSystemLoader(keyCodes: [keyCode]).translatedCharacters(
            from: source,
            modifierFlags: [modifierFlags],
            mode: .textInput,
            lowercased: false
        )
        return characters[KeyboardLayoutSnapshot.Key(
            keyCode: keyCode,
            modifierFlags: modifierFlags.intersection([.shift, .option])
        )]
    }
}
#endif
