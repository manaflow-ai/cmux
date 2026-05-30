import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellEnumWireTests {
    @Test func wideKindWireUsesSnakeCase() throws {
        #expect(try String(decoding: JSONEncoder().encode(WideKind.spacerTail), as: UTF8.self) == "\"spacer_tail\"")
        #expect(try String(decoding: JSONEncoder().encode(WideKind.spacerHead), as: UTF8.self) == "\"spacer_head\"")
    }

    @Test func cellAttributeDoesNotContainUnderline() {
        for raw in CellAttribute.allCases.map(\.rawValue) {
            #expect(raw != "underline")
        }
    }

    @Test func underlineKindWireValues() throws {
        #expect(try String(decoding: JSONEncoder().encode(UnderlineKind.single), as: UTF8.self) == "\"single\"")
        #expect(try String(decoding: JSONEncoder().encode(UnderlineKind.curly), as: UTF8.self) == "\"curly\"")
    }

    @Test func cellColorEncodingShapes() throws {
        #expect(try String(decoding: JSONEncoder().encode(CellColor.default), as: UTF8.self) == "\"default\"")
        let p = try JSONEncoder().encode(CellColor.palette(7))
        #expect(String(decoding: p, as: UTF8.self) == "{\"palette\":7}")
        let r = try JSONEncoder().encode(CellColor.rgb(r: 1, g: 2, b: 3))
        #expect(String(decoding: r, as: UTF8.self).contains("\"rgb\""))
    }

    @Test func semanticKindWire() throws {
        #expect(try String(decoding: JSONEncoder().encode(SemanticKind.promptContinuation), as: UTF8.self) == "\"prompt_continuation\"")
    }
}
