public import AppKit
public import CmuxNextDaemon
import Foundation

/// A key typed for a terminal whose view is not live yet (the launch picture, p08-startup-061), as the terminal's
/// owner takes it, so the key goes to the daemon by the terminal's id at once and no view has to be built for it:
/// - A key that commits text (a letter, a symbol, an Option character, a space) is that text, written as typed:
///   what Ghostty writes for such a key.
/// - A key Ghostty encodes from the key itself (Return, Tab, Escape, Delete, the arrows, Home, End, the page and
///   function keys, a Control chord) goes by its `send-key` name, and the daemon encodes it with the program's own
///   keyboard modes (cursor keys, the Kitty protocol): the daemon's Ghostty key encoder, the path a TUI's Command
///   chords take (`TerminalKeyEquivalent.sendToProgram`). The app's own surface could not encode it: it has not
///   read the terminal's modes before its replay.
///
/// A Command chord is never typing (nil), nor is a key that commits nothing (a dead key, a modifier).
public nonisolated enum TypedTerminalInput: Sendable, Equatable {
    /// Text the key commits.
    case text(String)
    /// The key's `send-key` name (`enter`, `ctrl+c`, `shift+tab`).
    case key(String)

    public init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard !flags.contains(.command) else { return nil }
        if let name = Self.namedKeys[event.keyCode] {
            self = .key(Self.chord(name, flags))
            return
        }
        if flags.contains(.control), let base = event.charactersIgnoringModifiers?.lowercased(),
           let name = base == " " ? "space" : (Self.chordCharacters.contains(base) ? base : nil) {
            self = .key(Self.chord(name, flags))
            return
        }
        // A function key with no name here commits AppKit's private-use character, never text.
        guard let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return nil }
        self = .text(text)
    }

    /// The `send-key` name of `name` with `flags` held: `ctrl+alt+shift+left`.
    private static func chord(_ name: String, _ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        return (parts + [name]).joined(separator: "+")
    }

    /// Keys by their virtual key code (Carbon's `kVK_`), named as `send-key` reads them
    /// (cmux-tui ghostty-vt `key_input_from_chord`).
    private static let namedKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 53: "escape", 51: "backspace", 117: "delete", 114: "insert",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    /// The characters a `send-key` Control chord names (letters, digits and the US keyboard's unshifted symbols).
    private static let chordCharacters: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789`\\[],=-.';/".map { String($0) })
}

extension DaemonService {
    /// Writes `inputs` into terminal `terminalID` (its host id), in order, from this daemon's connection: by the id
    /// when the daemon takes input by terminal id (`send {terminal_id}`, which also reaches a terminal that is
    /// still being created), else by `surface`; a ``TypedTerminalInput/key(_:)`` goes by `surface`
    /// (`send-key`). Before the first connection the inputs wait for it, as a terminal's attach does
    /// (``endpoint()``), never for a time.
    ///
    /// `answered` runs once on main: nil once the daemon took every input, or may have (a reply past its deadline
    /// is never sent again: the daemon may have written it), else why not (logged, never shown).
    public func type(_ inputs: [TypedTerminalInput], terminal terminalID: TerminalID?, surface: SurfaceID,
                     answered: @escaping @MainActor @Sendable (_ refusal: String?) -> Void) {
        guard !inputs.isEmpty else { return answered(nil) }
        let mainWork = mainWork, terminal = terminalID?.rawValue
        send("type-into-terminal", onFailure: { failure in
            answered(failure.mayHaveApplied ? nil : failure.description)
        }) { connection in
            let byID = terminal != nil && connection.identity?.supports(DaemonCapability.terminalInputWhileCreating.rawValue) == true
            for input in inputs {
                switch input {
                case .text(let text):
                    if byID, let terminal {
                        try await connection.sendTerminalInput(terminal, bytes: Data(text.utf8))
                    } else {
                        try await connection.send(surface, bytes: Data(text.utf8))
                    }
                case .key(let name):
                    try await connection.sendKeys(surface, [name])
                }
            }
            mainWork.postFromAnyThread(.userBlocking, owner: "DaemonService.typedInput") { answered(nil) }
        }
    }

    /// Runs `body` once this daemon has its first connection: now when it has one or is not starting (a command
    /// then fails as it would), else when the first connect ends (``firstConnection()``'s moment), on main.
    public func onFirstConnection(_ body: @escaping @MainActor () -> Void) {
        guard connection == nil, startup == .connecting, isStarting else { return body() }
        firstConnectionCallbacks.append(body)
    }
}
