import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Physical key source parsers")
struct PhysicalKeyParserTests {
    // `hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000029}]}'`
    // then `hidutil property --get UserKeyMapping`.
    static let hidutilCapsLockToEscape = """
    (
            {
            HIDKeyboardModifierMappingDst = 30064771113;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """

    @Test func readsHidutilOutput() {
        let mapping = HIDKeyMapping(hidutilOutput: Self.hidutilCapsLockToEscape)
        #expect(mapping.output(for: .capsLock) == .escape)
        #expect(mapping.output(for: .leftControl) == .leftControl)
    }

    @Test func readsHidutilHexAndEitherOrder() {
        let mapping = HIDKeyMapping(hidutilOutput: """
        ({HIDKeyboardModifierMappingSrc = 0x7000000E0; HIDKeyboardModifierMappingDst = 0x7000000E3;},
         {"HIDKeyboardModifierMappingDst": 30064771296, "HIDKeyboardModifierMappingSrc": 30064771299})
        """)
        #expect(mapping.output(for: .leftControl) == .leftCommand)
        #expect(mapping.output(for: .leftCommand) == .leftControl)
    }

    @Test func zeroUsageMeansNoAction() {
        #expect(PhysicalKey(hidUsage: 0) == .noAction)
        #expect(PhysicalKey(hidUsage: 0x7_0000_0000) == .noAction)
    }

    @Test func unsetHidutilMappingIsIdentity() {
        #expect(HIDKeyMapping(hidutilOutput: "(null)\n") == .identity)
        #expect(HIDKeyMapping(hidutilOutput: "") == .identity)
    }

    @Test func readsSystemSettingsModifierKeysPerKeyboard() throws {
        // `defaults -currentHost export -g -` after setting Caps Lock to
        // Control and Control to Caps Lock for one keyboard.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>com.apple.keyboard.modifiermapping.1452-834-0</key>
          <array>
            <dict>
              <key>HIDKeyboardModifierMappingDst</key><integer>30064771296</integer>
              <key>HIDKeyboardModifierMappingSrc</key><integer>30064771129</integer>
            </dict>
            <dict>
              <key>HIDKeyboardModifierMappingDst</key><integer>30064771129</integer>
              <key>HIDKeyboardModifierMappingSrc</key><integer>30064771296</integer>
            </dict>
          </array>
          <key>com.apple.keyboard.modifiermapping.0-0-0</key>
          <array>
            <dict>
              <key>HIDKeyboardModifierMappingDst</key><integer>30064771299</integer>
              <key>HIDKeyboardModifierMappingSrc</key><integer>30064771299</integer>
            </dict>
          </array>
          <key>AppleLanguages</key><array><string>en</string></array>
        </dict></plist>
        """
        let domain = try #require(
            try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        )
        let mappings = SystemModifierKeyMappings(globalDomains: [domain])
        let external = KeyboardDevice(name: "External", vendorID: 1452, productID: 834, isBuiltIn: false)
        let builtIn = KeyboardDevice(name: "Built-in", vendorID: 0, productID: 0, isBuiltIn: true)
        #expect(mappings.mapping(for: external).output(for: .capsLock) == .leftControl)
        #expect(mappings.mapping(for: external).output(for: .leftControl) == .capsLock)
        #expect(mappings.mapping(for: builtIn) == .identity)
    }

    @Test func currentHostModifierKeysWinOverAnyHost() {
        let anyHost: [String: Any] = ["com.apple.keyboard.modifiermapping.1-2-0": [
            ["HIDKeyboardModifierMappingSrc": 30064771129, "HIDKeyboardModifierMappingDst": 30064771296],
        ]]
        let currentHost: [String: Any] = ["com.apple.keyboard.modifiermapping.1-2-0": [
            ["HIDKeyboardModifierMappingSrc": 30064771129, "HIDKeyboardModifierMappingDst": 30064771113],
        ]]
        let device = KeyboardDevice(name: "K", vendorID: 1, productID: 2, isBuiltIn: false)
        let mappings = SystemModifierKeyMappings(globalDomains: [anyHost, currentHost])
        #expect(mappings.mapping(for: device).output(for: .capsLock) == .escape)
    }

    @Test func readsOnlyTheSelectedKarabinerProfile() throws {
        let json = """
        {"profiles": [
          {"name": "Other", "simple_modifications": [
            {"from": {"key_code": "caps_lock"}, "to": [{"key_code": "escape"}]}]},
          {"name": "Default", "selected": true, "simple_modifications": [
            {"from": {"key_code": "caps_lock"}, "to": [{"key_code": "left_control"}]},
            {"from": {"key_code": "right_command"}, "to": [{"consumer_key_code": "mute"}]},
            {"from": {"key_code": "f1"}, "to": []}],
           "devices": [
            {"identifiers": {"is_keyboard": true, "product_id": 268, "vendor_id": 9610},
             "simple_modifications": [{"from": {"key_code": "left_option"}, "to": [{"key_code": "left_control"}]}]},
            {"identifiers": {"is_keyboard": true, "product_id": 1, "vendor_id": 2}, "ignore": true}]}
        ]}
        """
        let profile = try #require(KarabinerProfile(configurationData: Data(json.utf8)))
        #expect(profile.simpleModifications[.capsLock] == .key(.leftControl))
        #expect(profile.simpleModifications[.rightCommand] == .unknown)
        #expect(profile.simpleModifications[try #require(PhysicalKey(karabinerKeyCode: "f1"))] == .key(.noAction))
        let yunzii = KeyboardDevice(name: "Y", vendorID: 9610, productID: 268, isBuiltIn: false)
        #expect(profile.deviceSettings(for: yunzii).settings?.simpleModifications[.leftOption] == .key(.leftControl))
        let ignored = KeyboardDevice(name: "I", vendorID: 2, productID: 1, isBuiltIn: false)
        #expect(profile.deviceSettings(for: ignored).settings?.ignore == true)
    }

    @Test func noSelectedProfileOrInvalidJSONReadsAsNoProfile() {
        #expect(KarabinerProfile(configurationData: Data(#"{"profiles": [{"name": "A"}]}"#.utf8)) == nil)
        #expect(KarabinerProfile(configurationData: Data("not json".utf8)) == nil)
    }

    @Test func readsPlainComplexManipulatorsAndMarksOthersUnsupported() throws {
        let json = """
        {"profiles": [{"selected": true, "complex_modifications": {"rules": [
          {"description": "plain", "manipulators": [
            {"type": "basic", "from": {"key_code": "o", "modifiers": {"mandatory": ["command"], "optional": ["any"]}},
             "to": [{"key_code": "o", "modifiers": ["left_control"]}]}]},
          {"description": "alone", "manipulators": [
            {"type": "basic", "from": {"key_code": "caps_lock"},
             "to": [{"key_code": "left_control"}], "to_if_alone": [{"key_code": "escape"}]}]},
          {"description": "two outputs", "manipulators": [
            {"type": "basic", "from": {"key_code": "b", "modifiers": {"mandatory": ["left_control"]}},
             "to": [{"key_code": "b", "modifiers": ["left_control"]}, {"key_code": "b", "modifiers": ["left_control"]}]}]},
          {"description": "disabled", "enabled": false, "manipulators": [
            {"type": "basic", "from": {"key_code": "x"}, "to": [{"key_code": "y"}]}]}
        ]}}]}
        """
        let profile = try #require(KarabinerProfile(configurationData: Data(json.utf8)))
        #expect(profile.manipulators.count == 3)
        #expect(profile.manipulators[0].from == .key(
            try #require(PhysicalKey(karabinerKeyCode: "o")),
            mandatory: [.either(.command)],
            optional: [.any]
        ))
        #expect(profile.manipulators[0].output == .key(try #require(PhysicalKey(karabinerKeyCode: "o")), modifiers: [.leftControl]))
        #expect(profile.manipulators[1].output == .unsupported)
        #expect(profile.manipulators[2].output == .unsupported)
    }
}
