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

    private struct InputSourceReader: KeyboardInputSourceReading, @unchecked Sendable {
        let source: TISInputSource

        func currentInputSource() -> TISInputSource? {
            source
        }

        func currentASCIICapableInputSource() -> TISInputSource? {
            nil
        }
    }

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
        let snapshot = KeyboardLayoutSystemLoader(
            inputSourceReader: InputSourceReader(source: source),
            keyCodes: [keyCode],
            shortcutModifierFlags: [],
            textInputModifierFlags: [modifierFlags]
        ).loadCurrentSnapshot()
        return snapshot?.textInputCharacter(
            forKeyCode: keyCode,
            modifierFlags: modifierFlags
        )
    }
}
#endif
