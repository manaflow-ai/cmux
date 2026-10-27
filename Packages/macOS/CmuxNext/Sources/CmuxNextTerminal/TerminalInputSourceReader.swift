import AppKit

/// The selected keyboard input source, as the terminal's key path needs it.
nonisolated struct TerminalInputSource: Equatable, Sendable {
    var id: String
    /// A plain keyboard layout (ABC, Russian), not an input method or one of its modes (Kotoeri's Hiragana).
    var isKeyboardLayout: Bool
}

/// The ASCII character each physical key types (`GhosttyInput.asciiKeyMap`), built once per layout.
nonisolated struct ASCIIKeyMap: Sendable {
    let characters: [UInt16: String]

    /// No characters: for a key that already types ASCII.
    static let empty = ASCIIKeyMap(characters: [:])

    func character(forKeyCode keyCode: UInt16) -> String? {
        characters[keyCode]
    }
}

/// Reads the system's input sources. The live reader calls Text Input Sources; tests count the calls.
nonisolated struct TerminalInputSourceReader {
    var current: () -> TerminalInputSource?
    var asciiKeyMap: () -> ASCIIKeyMap

    static var live: TerminalInputSourceReader {
        TerminalInputSourceReader(current: { GhosttyInput.currentInputSource() },
                                  asciiKeyMap: { ASCIIKeyMap(characters: GhosttyInput.asciiKeyMap()) })
    }
}
