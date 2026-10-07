import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalViewportTests {
    @Test func clampsToTwoByOne() {
        let viewport = TerminalViewport(cols: 0, rows: -3, visible: true)
        #expect(viewport.cols == 2 && viewport.rows == 1)
        #expect(TerminalViewport(cols: 46, rows: 38, visible: false) == TerminalViewport(cols: 46, rows: 38, visible: false))
    }
}
