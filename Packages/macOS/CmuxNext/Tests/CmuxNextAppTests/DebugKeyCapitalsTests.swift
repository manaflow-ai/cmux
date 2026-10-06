import AppKit
@testable import CmuxNextApp
import Testing

/// hqacp-v4: debug.key typed "Do" as "do" and "URL" as "URl". A capital whose lowercase is a named
/// key ("d", "l") took the name's lowercase character, and no capital carried Shift. A typed
/// character keeps its case and a capital letter has Shift, as from a keyboard.
@MainActor @Suite struct DebugKeyCapitalsTests {
    @Test func aCapitalLetterKeepsItsCaseAndHasShift() {
        for (name, keyCode) in [("D", UInt16(2)), ("L", 37), ("U", 32), ("R", 15), ("A", 0)] {
            let press = DebugKey.keyPress(name, modifiers: [])
            #expect(press.characters == name, "\(name) types \(name)")
            #expect(press.keyCode == keyCode)
            #expect(press.flags.contains(.shift), "\(name) has Shift")
        }
    }

    @Test func lowercaseLettersNamedKeysAndSymbolsAreUnchanged() {
        let d = DebugKey.keyPress("d", modifiers: [])
        #expect(d.characters == "d" && d.keyCode == 2 && d.flags.isEmpty)
        let ret = DebugKey.keyPress("return", modifiers: [])
        #expect(ret.characters == "\r" && ret.keyCode == 36 && ret.flags.isEmpty)
        let commandD = DebugKey.keyPress("d", modifiers: ["cmd"])
        #expect(commandD.flags == .command)
        let backTab = DebugKey.keyPress("tab", modifiers: ["shift"])
        #expect(backTab.characters == "\u{19}")
        let colon = DebugKey.keyPress(":", modifiers: [])
        #expect(colon.characters == ":")
    }
}
