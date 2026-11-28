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
        ("ArrowLeft", UInt16(123), "\u{F702}"),
        ("ArrowRight", UInt16(124), "\u{F703}"),
        ("ArrowDown", UInt16(125), "\u{F701}"),
        ("ArrowUp", UInt16(126), "\u{F700}"),
    ])
    func nativeDescriptorMapsBrowserArrows(_ input: (String, UInt16, String)) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: input.0))
        let native = try #require(event.nativeKey)

        #expect(native.keyCode == input.1)
        #expect(native.location == 0)
        #expect(native.modifiers.isEmpty)
        #expect(native.modifierKey == nil)
        #expect(native.characters == input.2)
        #expect(native.charactersIgnoringModifiers == input.2)
    }

    @Test
    func nativeDescriptorKeepsNumpadVirtualKeys() throws {
        let expected: [(String, UInt16)] = [
            ("NumpadEnter", 76),
            ("Numpad0", 82),
            ("Numpad1", 83),
            ("Numpad2", 84),
            ("Numpad3", 85),
            ("Numpad4", 86),
            ("Numpad5", 87),
            ("Numpad6", 88),
            ("Numpad7", 89),
            ("Numpad8", 91),
            ("Numpad9", 92),
        ]

        for (rawKey, keyCode) in expected {
            let event = try #require(BrowserKeyboardEvent(rawKey: rawKey))
            let native = try #require(event.nativeKey)
            #expect(native.keyCode == keyCode, "Unexpected native key code for \(rawKey)")
            #expect(native.location == 3)
            #expect(native.modifiers.contains(.numericPad))
            #expect(native.characters == nil)
        }
    }

    @Test
    func nativeDescriptorCarriesShiftedPrintableCharacters() throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: "A"))
        let native = try #require(event.nativeKey)

        #expect(native.keyCode == 0)
        #expect(native.modifiers == [.shift])
        #expect(native.characters == "A")
        #expect(native.charactersIgnoringModifiers == "a")
    }

    @Test(arguments: [
        ("ShiftLeft", UInt16(56), 1),
        ("ShiftRight", UInt16(60), 2),
        ("ControlLeft", UInt16(59), 1),
        ("ControlRight", UInt16(62), 2),
        ("AltLeft", UInt16(58), 1),
        ("AltRight", UInt16(61), 2),
        ("MetaLeft", UInt16(55), 1),
        ("MetaRight", UInt16(54), 2),
    ])
    func nativeDescriptorMapsModifierLocations(_ input: (String, UInt16, Int)) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: input.0))
        let native = try #require(event.nativeKey)

        #expect(native.keyCode == input.1)
        #expect(native.location == input.2)
        #expect(native.modifierKey != nil)
        #expect(native.modifierKey == Optional(native.modifiers))
    }

    @Test(arguments: ["Space", "Spacebar", "space", " "])
    func nativeDescriptorMapsSpaceAliases(_ rawKey: String) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: rawKey))
        let native = try #require(event.nativeKey)

        #expect(native.keyCode == 49)
        #expect(native.characters == " ")
        #expect(native.charactersIgnoringModifiers == " ")
    }

    @Test(arguments: [
        ("Enter", UInt16(36), "\r"),
        ("Tab", UInt16(48), "\t"),
        ("Home", UInt16(115), "\u{F729}"),
        ("PageDown", UInt16(121), "\u{F72D}"),
        ("F1", UInt16(122), "\u{F704}"),
    ])
    func nativeDescriptorCarriesSpecialKeyCharacters(_ input: (String, UInt16, String)) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: input.0))
        let native = try #require(event.nativeKey)

        #expect(native.keyCode == input.1)
        #expect(native.characters == input.2)
        #expect(native.charactersIgnoringModifiers == input.2)
    }

    @Test(arguments: ["AudioVolumeUp", "AltGraph", "opaque-key"])
    func opaqueKeysRemainOnCompatibilityPath(_ rawKey: String) throws {
        let event = try #require(BrowserKeyboardEvent(rawKey: rawKey))
        #expect(event.nativeKey == nil)
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
