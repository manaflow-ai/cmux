import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct KeyEventParserTests {
    @Test func plainNamedKey() throws {
        let ev = try KeyEvent.parse("Enter")
        #expect(ev.mods.isEmpty)
        #expect(ev.key == .enter)
    }

    @Test func ctrlPlusChar() throws {
        let ev = try KeyEvent.parse("Ctrl+C")
        #expect(ev.mods == [.ctrl])
        #expect(ev.key == .char("c"))
    }

    @Test func altLowercaseChar() throws {
        let ev = try KeyEvent.parse("Alt+x")
        #expect(ev.mods == [.alt])
        #expect(ev.key == .char("x"))
    }

    @Test func functionKey() throws {
        #expect(try KeyEvent.parse("F5").key == .f(5))
    }

    @Test func arrow() throws {
        #expect(try KeyEvent.parse("Up").key == .up)
    }

    @Test func multipleMods() throws {
        let ev = try KeyEvent.parse("Ctrl+Shift+Tab")
        #expect(ev.mods == [.ctrl, .shift])
        #expect(ev.key == .tab)
    }

    @Test(arguments: ["", "Ctrl+", "Ctrl+Foo", "Bogus", "F0", "F25", "Cmd", "+Enter"])
    func rejectsInvalid(_ s: String) {
        #expect(throws: KeyEventParseError.self) { try KeyEvent.parse(s) }
    }
}
