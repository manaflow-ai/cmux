@testable import CmuxTerminalDomain
import Testing

@Suite struct TerminalMacOSKeyMapTests {
    private let map = TerminalMacOSKeyMap()

    @Test func mapsWritingSystemAndNavigationKeysToCanonicalValues() {
        #expect(map.key(for: 0) == .keyA)
        #expect(map.key(for: 36) == .enter)
        #expect(map.key(for: 123) == .arrowLeft)
        #expect(map.key(for: 126) == .arrowUp)

        #expect(TerminalW3CKey.keyA.rawValue == 20)
        #expect(TerminalW3CKey.enter.rawValue == 58)
    }

    @Test func mapsFunctionAndKeypadKeysWithoutCollapsingTheirIdentity() {
        #expect(map.key(for: 122) == .f1)
        #expect(map.key(for: 111) == .f12)
        #expect(map.key(for: 76) == .numpadEnter)
        #expect(map.key(for: 82) == .numpad0)
        #expect(map.key(for: 65) == .numpadDecimal)

        #expect(TerminalW3CKey.f1.rawValue == 121)
        #expect(TerminalW3CKey.numpadEnter.rawValue == 97)
    }

    @Test func mapsLeftAndRightModifierKeysIndependently() {
        #expect(map.key(for: 56) == .shiftLeft)
        #expect(map.key(for: 60) == .shiftRight)
        #expect(map.key(for: 59) == .controlLeft)
        #expect(map.key(for: 62) == .controlRight)
        #expect(map.key(for: 58) == .altLeft)
        #expect(map.key(for: 61) == .altRight)
        #expect(map.key(for: 55) == .metaLeft)
        #expect(map.key(for: 54) == .metaRight)
    }

    @Test func rejectsEveryKeyCodeOutsideGhosttysFixedMacOSTable() {
        #expect(map.key(for: 127) == .unidentified)
        #expect(map.key(for: 128) == .unidentified)
        #expect(map.key(for: .max) == .unidentified)
    }
}
