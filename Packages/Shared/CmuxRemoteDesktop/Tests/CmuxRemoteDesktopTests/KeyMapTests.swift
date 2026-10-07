import CmuxRemoteDesktop
import Testing

@Suite("HID key tables")
struct KeyMapTests {
    let keysyms = HidKeysymMap()
    let mac = HidMacKeyCodeMap()

    @Test func lettersDigitsAndControlKeysMapToX11Keysyms() {
        #expect(keysyms.keysym(for: HidUsage(keyboard: 0x04)) == 0x61)
        #expect(keysyms.keysym(for: HidUsage(keyboard: 0x1D)) == 0x7A)
        #expect(keysyms.keysym(for: HidUsage(keyboard: 0x1E)) == 0x31)
        #expect(keysyms.keysym(for: HidUsage(keyboard: 0x27)) == 0x30)
        #expect(keysyms.keysym(for: .returnKey) == 0xFF0D)
        #expect(keysyms.keysym(for: .escape) == 0xFF1B)
        #expect(keysyms.keysym(for: .backspace) == 0xFF08)
        #expect(keysyms.keysym(for: .left) == 0xFF51)
        #expect(keysyms.keysym(for: HidUsage.function(1)!) == 0xFFBE)
        #expect(keysyms.keysym(for: HidUsage.function(12)!) == 0xFFC9)
        #expect(keysyms.keysym(for: .leftControl) == 0xFFE3)
        #expect(keysyms.keysym(for: .leftCommand) == 0xFFEB)
        #expect(keysyms.keysym(for: HidUsage(rawValue: 0x000C_00E9)) == nil)
    }

    @Test func textMapsPerScalar() {
        #expect(keysyms.keysyms(for: "aZ é\n") == [0x61, 0x5A, 0x20, 0xE9, 0xFF0D])
        #expect(keysyms.keysyms(for: "あ") == [0x0100_3042])
    }

    @Test func usagesMapToMacKeyCodesByUSPosition() {
        #expect(mac.keyCode(for: HidUsage(keyboard: 0x04)) == 0x00)
        #expect(mac.keyCode(for: HidUsage.key(for: "z")!) == 0x06)
        #expect(mac.keyCode(for: HidUsage.key(for: "5")!) == 0x17)
        #expect(mac.keyCode(for: .returnKey) == 0x24)
        #expect(mac.keyCode(for: .leftCommand) == 0x37)
        #expect(mac.keyCode(for: .up) == 0x7E)
        #expect(mac.keyCode(for: HidUsage.function(1)!) == 0x7A)
        // Every letter and digit has a key code.
        for id in UInt32(0x04)...0x27 { #expect(mac.keyCode(for: HidUsage(keyboard: id)) != nil, "\(id)") }
    }

    @Test func modifiersAreKnown() {
        #expect(HidUsage.leftShift.isModifier)
        #expect(HidUsage.rightCommand.isModifier)
        #expect(!HidUsage.tab.isModifier)
        #expect(HidUsage.key(for: "A") == HidUsage(keyboard: 0x04))
        #expect(HidUsage.key(for: "!") == nil)
    }
}
