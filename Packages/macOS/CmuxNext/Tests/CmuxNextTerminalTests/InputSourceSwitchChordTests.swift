import AppKit
import Carbon.HIToolbox
@testable import CmuxNextTerminal
import Testing

/// A terminal key reads Text Input Sources only when it may switch the input source, and copy mode
/// translates the layout once, not per key (`TerminalInputSources`, `InputSourceSwitchKeys`).
@MainActor @Suite struct InputSourceSwitchChordTests {
    /// A reader that counts its Text Input Sources reads and ASCII map builds.
    nonisolated final class FakeSystem {
        var source = TerminalInputSource(id: "com.apple.keylayout.ABC", isKeyboardLayout: true)
        var reads = 0
        var mapBuilds = 0
        var map: [UInt16: String] = [UInt16(kVK_ANSI_H): "h"]

        var reader: TerminalInputSourceReader {
            TerminalInputSourceReader(
                current: { [unowned self] in
                    reads += 1
                    return source
                },
                asciiKeyMap: { [unowned self] in
                    mapBuilds += 1
                    return ASCIIKeyMap(characters: map)
                })
        }
    }

    private static let space = UInt16(kVK_Space), keyC = UInt16(kVK_ANSI_C), keyE = UInt16(kVK_ANSI_E)
    private static let systemDefaults = InputSourceSwitchKeys(symbolicHotKeys: nil, fnUsageType: nil)

    /// A started cache under `system`, with the switch keys read; reads counted from zero.
    private static func started(_ system: FakeSystem) -> TerminalInputSources {
        let keys = systemDefaults
        let sources = TerminalInputSources(reader: system.reader, readSwitchKeys: { keys })
        sources.selectedSourceChanged()
        sources.switchKeys = keys
        system.reads = 0
        return sources
    }

    // MARK: Key path

    @Test func ctrlCUnderAKeyboardLayoutMakesNoTISRead() {
        let system = FakeSystem()
        let sources = Self.started(system)
        for _ in 0..<100 {
            #expect(!sources.mayChangeSource(keyCode: Self.keyC, flags: .control))
            #expect(!sources.mayChangeSource(keyCode: Self.keyC, flags: [.control, .shift]))
            #expect(!sources.mayChangeSource(keyCode: Self.keyE, flags: [.command, .option]))
        }
        #expect(system.reads == 0)
    }

    @Test func aPlainKeyNeverCompares() {
        let system = FakeSystem()
        let sources = Self.started(system)
        #expect(!sources.mayChangeSource(keyCode: Self.keyC, flags: []))
        #expect(!sources.mayChangeSource(keyCode: Self.keyC, flags: .shift))
        #expect(system.reads == 0)
    }

    @Test func ctrlSpaceStillDetectsTheSwitch() {
        let system = FakeSystem()
        let sources = Self.started(system)
        #expect(sources.mayChangeSource(keyCode: Self.space, flags: .control))
        #expect(sources.mayChangeSource(keyCode: Self.space, flags: [.control, .option]))
        let before = sources.currentSourceID()
        system.source = TerminalInputSource(id: "com.apple.keylayout.Russian", isKeyboardLayout: true)
        #expect(sources.sourceChanged(since: before))
        #expect(system.reads == 2)
    }

    @Test func aChordThatDidNotSwitchStillReachesTheTerminal() {
        let system = FakeSystem()
        let sources = Self.started(system)
        let before = sources.currentSourceID()
        #expect(!sources.sourceChanged(since: before))
    }

    @Test func anInputMethodComparesEveryChord() {
        let system = FakeSystem()
        system.source = TerminalInputSource(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", isKeyboardLayout: false)
        let sources = Self.started(system)
        #expect(sources.mayChangeSource(keyCode: UInt16(kVK_ANSI_J), flags: [.control, .shift]))
        #expect(system.reads == 0)
    }

    @Test func aSwitchToAnInputMethodByTheKeyIsRemembered() {
        let system = FakeSystem()
        let sources = Self.started(system)
        let before = sources.currentSourceID()
        system.source = TerminalInputSource(id: "com.apple.inputmethod.Korean.2SetKorean", isKeyboardLayout: false)
        #expect(sources.sourceChanged(since: before))
        system.reads = 0
        #expect(sources.mayChangeSource(keyCode: Self.keyC, flags: .control))
        #expect(system.reads == 0)
    }

    @Test func beforeTheSwitchKeysAreReadEveryChordCompares() {
        let system = FakeSystem()
        let keys = Self.systemDefaults
        let sources = TerminalInputSources(reader: system.reader, readSwitchKeys: { keys })
        #expect(sources.mayChangeSource(keyCode: Self.keyC, flags: .control))
        #expect(!sources.mayChangeSource(keyCode: Self.keyC, flags: []))
    }

    // MARK: Switch keys

    @Test func missingSettingsMeanTheSystemDefaults() {
        let keys = Self.systemDefaults
        #expect(keys.matches(keyCode: Self.space, flags: .control))
        #expect(keys.matches(keyCode: Self.space, flags: [.control, .option]))
        #expect(!keys.matches(keyCode: Self.space, flags: .command))
        #expect(!keys.matches(keyCode: Self.keyC, flags: .control))
        #expect(keys.globeChangesInputSource)
    }

    @Test func aDisabledOrReboundHotKeyFollowsTheSettings() {
        let command = NSNumber(value: NSEvent.ModifierFlags.command.rawValue)
        let parameters: [Any] = [NSNumber(value: 32), NSNumber(value: kVK_Space), command]
        let value: [String: Any] = ["parameters": parameters, "type": "standard"]
        let off: [String: Any] = ["enabled": NSNumber(value: 0)]
        let rebound: [String: Any] = ["enabled": NSNumber(value: 1), "value": value]
        let keys = InputSourceSwitchKeys(symbolicHotKeys: ["60": off, "61": rebound], fnUsageType: 0)
        #expect(!keys.matches(keyCode: Self.space, flags: .control))
        #expect(!keys.matches(keyCode: Self.space, flags: [.control, .option]))
        #expect(keys.matches(keyCode: Self.space, flags: .command))
        // Caps Lock does not take part.
        #expect(keys.matches(keyCode: Self.space, flags: [.command, .capsLock]))
    }

    @Test func anEntryWithNoEnabledKeyCountsAsOn() {
        let control = NSNumber(value: NSEvent.ModifierFlags.control.rawValue)
        let parameters: [Any] = [NSNumber(value: 32), NSNumber(value: kVK_Space), control]
        let valueOnly: [String: Any] = ["value": ["parameters": parameters] as [String: Any]]
        let keys = InputSourceSwitchKeys(symbolicHotKeys: ["60": valueOnly, "61": [String: Any]()], fnUsageType: 0)
        #expect(keys.matches(keyCode: Self.space, flags: .control))
        // An entry with neither key takes the system default.
        #expect(keys.matches(keyCode: Self.space, flags: [.control, .option]))
    }

    @Test func aHotKeyWithNoPhysicalKeyNeverMatches() {
        let parameters: [Any] = [NSNumber(value: 65535), NSNumber(value: 65535), NSNumber(value: 0)]
        let value: [String: Any] = ["parameters": parameters]
        let noKey: [String: Any] = ["enabled": true, "value": value]
        let off: [String: Any] = ["enabled": false]
        let keys = InputSourceSwitchKeys(symbolicHotKeys: ["60": noKey, "61": off], fnUsageType: 0)
        #expect(keys.hotKeys.isEmpty)
    }

    @Test func aGlobeChordComparesOnlyWhenGlobeChangesTheSource() {
        let globe = InputSourceSwitchKeys(symbolicHotKeys: nil, fnUsageType: 1)
        #expect(globe.matches(keyCode: Self.keyE, flags: .function))
        // Arrows and function keys carry Fn by themselves.
        #expect(!globe.matches(keyCode: UInt16(kVK_LeftArrow), flags: [.function, .control]))
        let emoji = InputSourceSwitchKeys(symbolicHotKeys: nil, fnUsageType: 2)
        #expect(!emoji.matches(keyCode: Self.keyE, flags: .function))
    }

    // MARK: Copy mode's ASCII map

    @Test func copyModeBuildsTheASCIIMapOncePerLayout() {
        let system = FakeSystem()
        let sources = Self.started(system)
        for _ in 0..<100 {
            #expect(sources.asciiKeyMap().character(forKeyCode: UInt16(kVK_ANSI_H)) == "h")
        }
        #expect(system.mapBuilds == 1)
        system.map = [UInt16(kVK_ANSI_H): "j"]
        sources.selectedSourceChanged()
        #expect(sources.asciiKeyMap().character(forKeyCode: UInt16(kVK_ANSI_H)) == "j")
        #expect(system.mapBuilds == 2)
    }

    @Test func aSourceSwitchByAKeyDropsTheASCIIMap() {
        let system = FakeSystem()
        let sources = Self.started(system)
        _ = sources.asciiKeyMap()
        let before = sources.currentSourceID()
        system.source = TerminalInputSource(id: "com.apple.keylayout.Russian", isKeyboardLayout: true)
        #expect(sources.sourceChanged(since: before))
        _ = sources.asciiKeyMap()
        #expect(system.mapBuilds == 2)
    }

    @Test func theEmptyMapHasNoCharacters() {
        #expect(ASCIIKeyMap.empty.character(forKeyCode: UInt16(kVK_ANSI_H)) == nil)
    }
}
