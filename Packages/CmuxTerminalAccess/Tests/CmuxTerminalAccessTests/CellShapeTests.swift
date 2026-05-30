import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellShapeTests {
    @Test func cellCarriesUnderlineKindAndColor() {
        let cell = Cell(
            t: "x", wide: .narrow, fg: .default, bg: .default,
            attrs: [.bold], underlineKind: .curly,
            underlineColor: .rgb(r: 9, g: 8, b: 7),
            hyperlink: "https://example.com", semantic: nil)
        #expect(cell.underlineKind == .curly)
        #expect(cell.underlineColor == .rgb(r: 9, g: 8, b: 7))
        #expect(cell.hyperlink == "https://example.com")
    }

    @Test func cellRowSnakeCaseWrap() throws {
        let row = CellRow(wrap: true, wrapContinuation: false, cells: [])
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(json.contains("\"wrap_continuation\":false"))
        #expect(json.contains("\"wrap\":true"))
    }

    @Test func cellOmitsNilsInJSON() throws {
        let cell = Cell(t: "y", wide: .narrow, fg: .default, bg: .default,
                        attrs: [], underlineKind: nil, underlineColor: nil,
                        hyperlink: nil, semantic: nil)
        let data = try JSONEncoder().encode(cell)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["underline_kind"] == nil)
        #expect(obj?["hyperlink"] == nil)
    }

    @Test func cursorStateRoundTrip() throws {
        let cs = CursorState(row: 3, col: 4, visible: false, style: .bar)
        let back = try JSONDecoder().decode(CursorState.self,
                                            from: JSONEncoder().encode(cs))
        #expect(back == cs)
    }
}
