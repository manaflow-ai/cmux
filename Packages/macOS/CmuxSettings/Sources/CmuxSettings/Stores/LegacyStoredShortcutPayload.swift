import Foundation

/// The flat Codable representation written by the app's legacy shortcut store.
struct LegacyStoredShortcutPayload: Decodable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool
    let keyCode: UInt16?
    let chordKey: String?
    let chordCommand: Bool
    let chordShift: Bool
    let chordOption: Bool
    let chordControl: Bool
    let chordKeyCode: UInt16?

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case keyCode
        case chordKey
        case chordCommand
        case chordShift
        case chordOption
        case chordControl
        case chordKeyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        command = try container.decode(Bool.self, forKey: .command)
        shift = try container.decode(Bool.self, forKey: .shift)
        option = try container.decode(Bool.self, forKey: .option)
        control = try container.decode(Bool.self, forKey: .control)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        chordKey = try container.decodeIfPresent(String.self, forKey: .chordKey)
        chordCommand = try container.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false
        chordShift = try container.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false
        chordOption = try container.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false
        chordControl = try container.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false
        chordKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .chordKeyCode)
    }

    var storedShortcut: StoredShortcut {
        let second = chordKey.flatMap { key -> ShortcutStroke? in
            guard !key.isEmpty else { return nil }
            return ShortcutStroke(
                key: key,
                command: chordCommand,
                shift: chordShift,
                option: chordOption,
                control: chordControl,
                keyCode: chordKeyCode
            )
        }
        return StoredShortcut(
            first: ShortcutStroke(
                key: key,
                command: command,
                shift: shift,
                option: option,
                control: control,
                keyCode: keyCode
            ),
            second: second
        )
    }
}
