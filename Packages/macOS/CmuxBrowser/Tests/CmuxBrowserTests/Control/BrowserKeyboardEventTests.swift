import Testing
@testable import CmuxBrowser

@Suite
struct BrowserKeyboardEventTests {
    @Test(arguments: ["Space", "Spacebar", "space", " "])
    func spaceAliasesUseTheDOMSpaceKey(_ rawKey: String) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: rawKey))

        #expect(event.key == " ")
        #expect(event.code == "Space")
        #expect(event.legacyKeyCode == 32)
        #expect(event.location == 0)
    }

    @Test
    func rawRPCValidationRejectsOnlyMissingOrEmptyKeys() throws {
        #expect(BrowserKeyboardEvent(rawKey: nil) == nil)
        #expect(BrowserKeyboardEvent(rawKey: "") == nil)

        let space = try #require(BrowserKeyboardEvent(rawKey: " "))
        #expect(space.key == " ")
    }

    @Test
    func mapsRepresentativePlaywrightKeyNames() throws {
        let cases: [(raw: String, key: String, code: String, keyCode: Int, location: Int)] = [
            ("Enter", "Enter", "Enter", 13, 0),
            ("Escape", "Escape", "Escape", 27, 0),
            ("ArrowLeft", "ArrowLeft", "ArrowLeft", 37, 0),
            ("KeyA", "a", "KeyA", 65, 0),
            ("Digit1", "1", "Digit1", 49, 0),
            ("ShiftLeft", "Shift", "ShiftLeft", 16, 1),
            ("ShiftRight", "Shift", "ShiftRight", 16, 2),
            ("Control", "Control", "ControlLeft", 17, 1),
            ("ControlRight", "Control", "ControlRight", 17, 2),
            ("AltLeft", "Alt", "AltLeft", 18, 1),
            ("AltRight", "Alt", "AltRight", 18, 2),
            ("NumpadEnter", "Enter", "NumpadEnter", 13, 3),
        ]

        for expected in cases {
            let event = try #require(BrowserKeyboardEvent(rawKey: expected.raw))
            #expect(event.key == expected.key)
            #expect(event.code == expected.code)
            #expect(event.legacyKeyCode == expected.keyCode)
            #expect(event.location == expected.location)
        }
    }

    @Test(arguments: [
        BrowserKeyboardAction.press,
        BrowserKeyboardAction.keyDown,
        BrowserKeyboardAction.keyUp,
    ])
    func everyActionUsesTheSameCanonicalMapping(_ action: BrowserKeyboardAction) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: "Space"))
        let script = BrowserControlService().keyboardScript(action: action, event: event)

        #expect(script.contains("const __cmuxKeyValue = \" \";"))
        #expect(script.contains("const __cmuxCodeValue = \"Space\";"))
    }
}
