import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct CellGridCodableTests {
    @Test func roundTrip() throws {
        let cell = Cell(t: "H", wide: .narrow, fg: .default, bg: .default,
                        attrs: [.bold], underlineKind: .single,
                        underlineColor: nil, hyperlink: nil, semantic: .prompt)
        let row = CellRow(wrap: false, wrapContinuation: false, cells: [cell])
        let grid = CellGrid(cols: 1, rows: 1, altScreen: false, title: "t",
                            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                            semanticAvailable: true, rowsData: [row])
        let back = try JSONDecoder().decode(CellGrid.self,
                                            from: JSONEncoder().encode(grid))
        #expect(back == grid)
    }

    @Test func usesSnakeCaseTopKeys() throws {
        let grid = CellGrid(cols: 80, rows: 24, altScreen: true, title: nil,
                            cursor: CursorState(row: 0, col: 0, visible: false, style: .bar),
                            semanticAvailable: false, rowsData: [])
        let json = String(decoding: try JSONEncoder().encode(grid), as: UTF8.self)
        #expect(json.contains("\"alt_screen\":true"))
        #expect(json.contains("\"semantic_available\":false"))
        #expect(json.contains("\"rows_data\":[]"))
        #expect(json.contains("\"rows\":24"))
    }

    @Test func screenReadResultEncodesAsTaggedUnion() throws {
        let p = TextScreenPayload(cols: 1, rows: 1, altScreen: false, title: nil, text: "")
        let json = String(decoding: try JSONEncoder().encode(ScreenReadResult.text(p)), as: UTF8.self)
        #expect(json.contains("\"format\":\"text\""))
    }
}
