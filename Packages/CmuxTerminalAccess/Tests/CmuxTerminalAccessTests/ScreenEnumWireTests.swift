import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct ScreenEnumWireTests {
    @Test func wireValuesAreLowercase() throws {
        #expect(try String(decoding: JSONEncoder().encode(ScreenFormat.text), as: UTF8.self) == "\"text\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenFormat.cells), as: UTF8.self) == "\"cells\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.viewport), as: UTF8.self) == "\"viewport\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.screen), as: UTF8.self) == "\"screen\"")
        #expect(try String(decoding: JSONEncoder().encode(ScreenRegion.scrollback), as: UTF8.self) == "\"scrollback\"")
        #expect(try String(decoding: JSONEncoder().encode(WrapPolicy.preserve), as: UTF8.self) == "\"preserve\"")
        #expect(try String(decoding: JSONEncoder().encode(WrapPolicy.join), as: UTF8.self) == "\"join\"")
    }
}
