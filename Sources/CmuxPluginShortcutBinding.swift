import CmuxSettings
import Foundation

/// Language-readable JSON representation for one dynamic plugin shortcut.
///
/// Single strokes are written as strings, chords as two-string arrays, and
/// explicit unbinds as `null`, matching the public `cmux.json` shortcut syntax.
struct CmuxPluginShortcutBinding: SettingCodable {
    let strokes: [String]

    init(_ shortcut: StoredShortcut) {
        if shortcut.isUnbound {
            strokes = []
        } else if let secondStroke = shortcut.secondStroke {
            strokes = [
                shortcut.firstStroke.configString(),
                secondStroke.configString(),
            ]
        } else {
            strokes = [shortcut.firstStroke.configString()]
        }
    }

    var shortcut: StoredShortcut? {
        if strokes.isEmpty { return .unbound }
        return StoredShortcut.parseConfig(strokes: strokes, allowBareFirstStroke: false)
    }

    static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        decode(raw)
    }

    func encodeForUserDefaults() -> Any {
        if strokes.isEmpty { return "none" }
        if strokes.count == 1 { return strokes[0] }
        return strokes
    }

    static func decodeFromJSON(_ raw: Any?) -> Self? {
        decode(raw)
    }

    func encodeForJSON() -> Any {
        if strokes.isEmpty { return NSNull() }
        if strokes.count == 1 { return strokes[0] }
        return strokes
    }

    private static func decode(_ raw: Any?) -> Self? {
        if raw is NSNull { return Self(strokes: []) }
        let strokes: [String]
        if let string = raw as? String {
            strokes = [string]
        } else if let values = raw as? [String] {
            strokes = values
        } else {
            return nil
        }
        guard let shortcut = StoredShortcut.parseConfig(
            strokes: strokes,
            allowBareFirstStroke: false
        ) else {
            return nil
        }
        return Self(shortcut)
    }

    private init(strokes: [String]) {
        self.strokes = strokes
    }
}
