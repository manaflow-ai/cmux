import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Physical keys for agent key hints")
struct PhysicalKeyRemapTests {
    private let builtIn = KeyboardDevice(name: "Apple Internal Keyboard / Trackpad", vendorID: 0, productID: 0, isBuiltIn: true)
    private let external = KeyboardDevice(name: "External Keyboard", vendorID: 9610, productID: 268, isBuiltIn: false)
    private let karabinerVirtual = KeyboardDevice(
        name: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0", vendorID: 1452, productID: 591, isBuiltIn: false
    )
    private let cmux = KarabinerFrontmostApplication(bundleIdentifier: "com.cmuxterm.app", executablePath: nil)

    private func key(_ name: String) throws -> PhysicalKey {
        try #require(PhysicalKey(karabinerKeyCode: name))
    }

    private func setup(
        keyboards: [KeyboardDevice]? = nil,
        karabiner: String? = nil,
        hidutil: String = "(null)",
        modifierKeys: SystemModifierKeyMappings = .none
    ) throws -> PhysicalKeyboardSetup {
        let profile = try karabiner.map { try #require(KarabinerProfile(configurationData: Data($0.utf8))) }
        return PhysicalKeyboardSetup(
            connectedKeyboards: keyboards ?? [builtIn] + (karabiner == nil ? [] : [karabinerVirtual]),
            karabiner: profile,
            userKeyMapping: HIDKeyMapping(hidutilOutput: hidutil),
            modifierKeys: modifierKeys,
            application: cmux
        )
    }

    private func profile(simple: String = "[]", devices: String = "[]", rules: String = "[]") -> String {
        """
        {"profiles": [{"selected": true, "simple_modifications": \(simple), "devices": \(devices),
          "complex_modifications": {"rules": \(rules)}}]}
        """
    }

    // MARK: No remaps

    @Test func withoutRemapsTheHintIsPressedAsPrinted() throws {
        let remap = try setup().remap(for: builtIn)
        for agentKey in ["ctrl+o", "shift+tab", "escape", "alt+m", "ctrl+b", "down"] {
            #expect(remap.resolve(agentKey: agentKey) == .asPrinted)
        }
        #expect(try setup().advice(forAgentKeys: ["ctrl+o"]).isEmpty)
    }

    // MARK: macOS

    @Test func systemSettingsCapsLockControlSwapShowsCapsLock() throws {
        let swap = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [.capsLock: .leftControl, .leftControl: .capsLock]),
        ])
        let resolution = try setup(modifierKeys: swap).remap(for: builtIn).resolve(agentKey: "ctrl+o")
        #expect(resolution == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [.capsLock], key: try key("o")),
            notes: [PhysicalKeyNote(physical: .capsLock, sends: .leftControl)],
            viaKarabinerRule: false
        )))
        guard case let .press(press) = resolution else { return }
        #expect(press.chord.glyphs == "⇪O")
    }

    @Test func capsLockAsAnExtraControlKeepsThePrintedChord() throws {
        // Control still works, so the hint is right as printed.
        let extra = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [.capsLock: .leftControl]),
        ])
        #expect(try setup(modifierKeys: extra).remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func hidutilCapsLockToEscapeShowsCapsLockForEscape() throws {
        let remap = try setup(hidutil: PhysicalKeyParserTests.hidutilCapsLockToEscape).remap(for: builtIn)
        // Escape still sends Escape, so pressing it works.
        #expect(remap.resolve(agentKey: "escape") == .asPrinted)

        let swapped = try setup(hidutil: """
        ({HIDKeyboardModifierMappingSrc = 30064771129; HIDKeyboardModifierMappingDst = 30064771113;},
         {HIDKeyboardModifierMappingSrc = 30064771113; HIDKeyboardModifierMappingDst = 30064771129;})
        """).remap(for: builtIn)
        #expect(swapped.resolve(agentKey: "escape") == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [], key: .capsLock),
            notes: [PhysicalKeyNote(physical: .capsLock, sends: .escape)],
            viaKarabinerRule: false
        )))
    }

    // MARK: Karabiner simple modifications

    @Test func karabinerSimpleSwapShowsCommand() throws {
        let json = profile(simple: """
        [{"from": {"key_code": "left_command"}, "to": [{"key_code": "left_control"}]},
         {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]}]
        """)
        let resolution = try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o")
        #expect(resolution == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [.leftCommand], key: try key("o")),
            notes: [PhysicalKeyNote(physical: .leftCommand, sends: .leftControl)],
            viaKarabinerRule: false
        )))
    }

    @Test func karabinerAppliesOnlyWhileItsVirtualKeyboardExists() throws {
        let json = profile(simple: """
        [{"from": {"key_code": "left_command"}, "to": [{"key_code": "left_control"}]},
         {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]}]
        """)
        let notRunning = try setup(keyboards: [builtIn], karabiner: json)
        #expect(notRunning.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func karabinerDeviceEntriesApplyToTheirKeyboardOnly() throws {
        // The left Control of this keyboard sends Command, and its left
        // Option sends Control; the built-in keyboard is untouched.
        let json = profile(devices: """
        [{"identifiers": {"is_keyboard": true, "product_id": 268, "vendor_id": 9610},
          "simple_modifications": [
            {"from": {"key_code": "left_command"}, "to": [{"key_code": "left_option"}]},
            {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]},
            {"from": {"key_code": "left_option"}, "to": [{"key_code": "left_control"}]}]}]
        """)
        let setup = try setup(keyboards: [builtIn, external, karabinerVirtual], karabiner: json)
        #expect(setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
        #expect(setup.remap(for: external).resolve(agentKey: "ctrl+o") == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [.leftOption], key: try key("o")),
            notes: [PhysicalKeyNote(physical: .leftOption, sends: .leftControl)],
            viaKarabinerRule: false
        )))
        #expect(setup.advice(forAgentKeys: ["ctrl+o"]) == [PhysicalKeyAdvice(
            keyboardNames: ["External Keyboard"],
            appliesToEveryKeyboard: false,
            chords: [PhysicalKeyChord(modifiers: [.leftOption], key: try key("o"))],
            notes: [PhysicalKeyNote(physical: .leftOption, sends: .leftControl)],
            viaKarabinerRule: false
        )])
    }

    @Test func ignoredKarabinerDeviceUsesItsOwnModifierKeys() throws {
        let json = profile(
            simple: #"[{"from": {"key_code": "left_option"}, "to": [{"key_code": "left_control"}]}, {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_option"}]}]"#,
            devices: #"[{"identifiers": {"is_keyboard": true, "product_id": 268, "vendor_id": 9610}, "ignore": true}]"#
        )
        let setup = try setup(keyboards: [external, karabinerVirtual], karabiner: json)
        #expect(setup.remap(for: external).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func systemSettingsForKarabinersVirtualKeyboardApplyToKeyboardsItManages() throws {
        let json = profile()
        let virtualSwap = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 1452, productID: 591): HIDKeyMapping(destinations: [.leftCommand: .leftControl, .leftControl: .leftCommand]),
        ])
        let setup = try setup(karabiner: json, modifierKeys: virtualSwap)
        guard case let .press(press) = setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.glyphs == "⌘O")
    }

    // MARK: Karabiner complex modifications

    @Test func plainComplexRuleIsInverted() throws {
        let json = profile(rules: """
        [{"description": "swap cmd+o and ctrl+o", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["control"]}},
           "to": [{"key_code": "o", "modifiers": ["left_command"]}]},
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["command"]}},
           "to": [{"key_code": "o", "modifiers": ["left_control"]}]}]}]
        """)
        let resolution = try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o")
        #expect(resolution == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [.leftCommand], key: try key("o")),
            notes: [],
            viaKarabinerRule: true
        )))
    }

    @Test func complexRuleConditionedOnCmuxApplies() throws {
        let json = profile(rules: """
        [{"description": "cmux only", "manipulators": [
          {"type": "basic", "from": {"key_code": "tab", "modifiers": {"mandatory": ["left_shift"]}},
           "to": [{"key_code": "tab", "modifiers": ["left_control"]}],
           "conditions": [{"type": "frontmost_application_if", "bundle_identifiers": ["^com\\\\.cmuxterm\\\\.app(?:\\\\..*)?$"]}]},
          {"type": "basic", "from": {"key_code": "tab", "modifiers": {"mandatory": ["left_control"]}},
           "to": [{"key_code": "tab", "modifiers": ["left_shift"]}],
           "conditions": [{"type": "frontmost_application_if", "bundle_identifiers": ["^com\\\\.cmuxterm\\\\.app(?:\\\\..*)?$"]}]}]}]
        """)
        guard case let .press(press) = try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "shift+tab") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.glyphs == "⌃⇥")
        #expect(press.viaKarabinerRule)
    }

    @Test func complexRuleForAnotherAppIsSkipped() throws {
        let json = profile(rules: """
        [{"description": "other app", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["control"]}},
           "to": [{"key_code": "o", "modifiers": ["left_command"]}],
           "conditions": [{"type": "frontmost_application_if", "bundle_identifiers": ["^com\\\\.apple\\\\.Safari$"]}]}]}]
        """)
        #expect(try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func deviceConditionAppliesToThatKeyboard() throws {
        let json = profile(rules: """
        [{"description": "external only", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["control"]}},
           "to": [{"key_code": "o", "modifiers": ["left_command"]}],
           "conditions": [{"type": "device_if", "identifiers": [{"vendor_id": 9610, "product_id": 268}]}]},
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["command"]}},
           "to": [{"key_code": "o", "modifiers": ["left_control"]}],
           "conditions": [{"type": "device_if", "identifiers": [{"vendor_id": 9610, "product_id": 268}]}]}]}]
        """)
        let setup = try setup(keyboards: [builtIn, external, karabinerVirtual], karabiner: json)
        #expect(setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
        guard case let .press(press) = setup.remap(for: external).resolve(agentKey: "ctrl+o") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.glyphs == "⌘O")
    }

    // MARK: Unknown shapes leave the printed chord

    @Test func toIfAloneRuleOnTheChordLeavesThePrintedChord() throws {
        let json = profile(rules: """
        [{"description": "ctrl+o alone", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["control"]}},
           "to": [{"key_code": "o", "modifiers": ["left_command"]}], "to_if_alone": [{"key_code": "escape"}]},
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["command"]}},
           "to": [{"key_code": "o", "modifiers": ["left_control"]}]}]}]
        """)
        #expect(try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func capsLockControlWithEscapeAloneIsNotGuessed() throws {
        // The common "Caps Lock is Control, Escape when tapped" rule plus
        // Control turned into Command: cmux can't tell what Caps Lock sends.
        let json = profile(
            simple: #"[{"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]}]"#,
            rules: """
            [{"description": "caps", "manipulators": [
              {"type": "basic", "from": {"key_code": "caps_lock", "modifiers": {"optional": ["any"]}},
               "to": [{"key_code": "left_control"}], "to_if_alone": [{"key_code": "escape"}]}]}]
            """
        )
        let remap = try setup(karabiner: json).remap(for: builtIn)
        // Caps Lock is not offered; right Control is the sure way.
        #expect(remap.resolve(agentKey: "ctrl+o") == .press(PhysicalKeyPress(
            chord: PhysicalKeyChord(modifiers: [.rightControl], key: try key("o")),
            notes: [],
            viaKarabinerRule: false
        )))
    }

    @Test func leftSideOnlyRuleOffersTheRightModifier() throws {
        let json = profile(rules: """
        [{"description": "left ctrl+o is cmd+o", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["left_control"], "optional": ["any"]}},
           "to": [{"key_code": "o", "modifiers": ["left_command"]}]}]}]
        """)
        guard case let .press(press) = try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.rightHandModifiers == [.rightControl])
    }

    @Test func bareKeyboardDeviceEntryIsTheBuiltInKeyboardOnly() throws {
        // Karabiner leaves out zero ids: this entry is the built-in keyboard.
        let json = profile(devices: """
        [{"identifiers": {"is_keyboard": true},
          "simple_modifications": [
            {"from": {"key_code": "left_command"}, "to": [{"key_code": "left_control"}]},
            {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]}]}]
        """)
        let setup = try setup(keyboards: [builtIn, external, karabinerVirtual], karabiner: json)
        #expect(setup.remap(for: external).resolve(agentKey: "ctrl+o") == .asPrinted)
        guard case let .press(press) = setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.glyphs == "⌘O")
    }

    @Test func uncheckableDeviceEntryMakesThatKeyboardUnknown() throws {
        let json = profile(
            simple: #"[{"from": {"key_code": "left_command"}, "to": [{"key_code": "left_control"}]}, {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_command"}]}]"#,
            devices: #"[{"identifiers": {"is_keyboard": true, "product_id": 268, "vendor_id": 9610, "device_address": "aa-bb"}, "ignore": true}]"#
        )
        let setup = try setup(keyboards: [external, karabinerVirtual], karabiner: json)
        #expect(setup.remap(for: external).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func unreadableKarabinerConfigurationWhileItRunsIsUnknown() {
        let swap = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [.capsLock: .leftControl, .leftControl: .capsLock]),
        ])
        let setup = PhysicalKeyboardSetup(
            connectedKeyboards: [builtIn, karabinerVirtual],
            karabiner: nil,
            userKeyMapping: .identity,
            modifierKeys: swap,
            application: cmux
        )
        #expect(setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
        // Without karabiner.json, Karabiner remaps nothing and macOS applies
        // the virtual keyboard's modifier keys, not the built-in one's.
        let empty = PhysicalKeyboardSetup(
            connectedKeyboards: [builtIn, karabinerVirtual],
            karabiner: .empty,
            userKeyMapping: .identity,
            modifierKeys: swap,
            application: cmux
        )
        #expect(empty.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func unreadableHidutilMappingIsUnknownNotUnmapped() {
        let swap = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [.capsLock: .leftControl, .leftControl: .capsLock]),
        ])
        let setup = PhysicalKeyboardSetup(
            connectedKeyboards: [builtIn],
            karabiner: nil,
            userKeyMapping: nil,
            modifierKeys: swap,
            application: cmux
        )
        #expect(setup.remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
        #expect(setup.advice(forAgentKeys: ["ctrl+o"]).isEmpty)
    }

    @Test func karabinerKeyNameAliasesAreRead() throws {
        let json = profile(simple: """
        [{"from": {"key_code": "left_gui"}, "to": [{"key_code": "left_control"}]},
         {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_gui"}]}]
        """)
        guard case let .press(press) = try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") else {
            Issue.record("expected a physical chord")
            return
        }
        #expect(press.chord.glyphs == "⌘O")
    }

    @Test func variableConditionOnTheChordLeavesThePrintedChord() throws {
        let json = profile(rules: """
        [{"description": "layer", "manipulators": [
          {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["control"]}},
           "to": [{"key_code": "p", "modifiers": ["left_control"]}],
           "conditions": [{"type": "variable_if", "name": "layer", "value": 1}]}]}]
        """)
        #expect(try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    @Test func unsupportedKeysLeaveThePrintedChord() throws {
        let remap = try setup().remap(for: builtIn)
        #expect(remap.resolve(agentKey: "?") == .asPrinted)
        #expect(remap.resolve(agentKey: "ctrl+nonsense") == .asPrinted)
    }

    @Test func twoEquallyGoodChordsLeaveThePrintedChord() throws {
        // Both Caps Lock and left Option send Control, and left Control doesn't.
        let json = profile(simple: """
        [{"from": {"key_code": "caps_lock"}, "to": [{"key_code": "left_control"}]},
         {"from": {"key_code": "left_option"}, "to": [{"key_code": "left_control"}]},
         {"from": {"key_code": "left_control"}, "to": [{"key_code": "left_option"}]},
         {"from": {"key_code": "right_control"}, "to": [{"key_code": "right_option"}]}]
        """)
        #expect(try setup(karabiner: json).remap(for: builtIn).resolve(agentKey: "ctrl+o") == .asPrinted)
    }

    // MARK: Advice

    @Test func adviceCoversRepeatedChordsAndEveryKeyboard() throws {
        let swap = SystemModifierKeyMappings(mappings: [
            .init(vendorID: 0, productID: 0): HIDKeyMapping(destinations: [.capsLock: .leftControl, .leftControl: .capsLock]),
        ])
        let advice = try setup(modifierKeys: swap).advice(forAgentKeys: ["ctrl+b", "ctrl+b"])
        let chord = PhysicalKeyChord(modifiers: [.capsLock], key: try key("b"))
        #expect(advice == [PhysicalKeyAdvice(
            keyboardNames: ["Apple Internal Keyboard / Trackpad"],
            appliesToEveryKeyboard: true,
            chords: [chord, chord],
            notes: [PhysicalKeyNote(physical: .capsLock, sends: .leftControl)],
            viaKarabinerRule: false
        )])
    }

    @Test func karabinerVirtualKeyboardIsNotListedAsAKeyboard() throws {
        let setup = try setup(keyboards: [builtIn, karabinerVirtual, builtIn], karabiner: profile())
        #expect(setup.keyboards == [builtIn])
    }
}
