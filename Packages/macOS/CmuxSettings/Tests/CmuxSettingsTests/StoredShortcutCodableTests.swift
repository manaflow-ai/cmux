import Foundation
import Testing
import CmuxSettings

@Suite("StoredShortcut Codable")
struct StoredShortcutCodableTests {
    @Test func legacySingleStrokeDecodes() throws {
        let data = Data(
            #"""
            {
              "key": "t",
              "command": true,
              "shift": false,
              "option": false,
              "control": false,
              "keyCode": 17,
              "chordCommand": false,
              "chordShift": false,
              "chordOption": false,
              "chordControl": false
            }
            """#.utf8
        )

        let shortcut = try JSONDecoder().decode(StoredShortcut.self, from: data)

        #expect(
            shortcut.first
                == ShortcutStroke(
                    key: "t",
                    command: true,
                    keyCode: 17
                )
        )
        #expect(shortcut.second == nil)
    }

    @Test func legacyChordDecodes() throws {
        let data = Data(
            #"""
            {
              "key": "b",
              "command": false,
              "shift": false,
              "option": false,
              "control": true,
              "keyCode": 11,
              "chordKey": "c",
              "chordCommand": false,
              "chordShift": true,
              "chordOption": false,
              "chordControl": false,
              "chordKeyCode": 8
            }
            """#.utf8
        )

        let shortcut = try JSONDecoder().decode(StoredShortcut.self, from: data)

        #expect(
            shortcut.first
                == ShortcutStroke(
                    key: "b",
                    control: true,
                    keyCode: 11
                )
        )
        #expect(
            shortcut.second
                == ShortcutStroke(
                    key: "c",
                    shift: true,
                    keyCode: 8
                )
        )
    }

    @Test func legacyUnboundDecodesFromUserDefaults() {
        let data = Data(
            #"""
            {
              "key": "",
              "command": false,
              "shift": false,
              "option": false,
              "control": false,
              "chordCommand": false,
              "chordShift": false,
              "chordOption": false,
              "chordControl": false
            }
            """#.utf8
        )

        #expect(StoredShortcut.decodeFromUserDefaults(data) == .unbound)
    }

    @Test func currentNestedFormatRoundTrips() throws {
        let original = StoredShortcut(
            first: ShortcutStroke(
                key: "p",
                command: true,
                shift: true,
                keyCode: 35
            ),
            second: ShortcutStroke(
                key: "k",
                option: true,
                keyCode: 40
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredShortcut.self, from: data)

        #expect(decoded == original)
    }
}
