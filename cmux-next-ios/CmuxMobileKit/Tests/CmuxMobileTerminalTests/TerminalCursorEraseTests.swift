@testable import CmuxMobileTerminal
import Testing

/// VERIFY-round8 claim 8 (D11 polish, T-LIFE-06): the frame saved for the
/// next cold launch hid the cursor by filling its cell with the background,
/// so the glyph under it went too (`› sk Codex` for `› Ask Codex`). Hiding
/// the cursor keeps the cell's character.
@Suite struct TerminalCursorEraseTests {
    let background: (UInt8, UInt8, UInt8) = (16, 16, 20)
    let cursor: (UInt8, UInt8, UInt8) = (220, 220, 220)
    let width = 10, height = 20

    func cell(fill: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4] = fill.0; pixels[i * 4 + 1] = fill.1; pixels[i * 4 + 2] = fill.2 }
        return pixels
    }

    func set(_ pixels: inout [UInt8], _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * width + x) * 4
        pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2
    }

    func get(_ pixels: [UInt8], _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    func erase(_ pixels: inout [UInt8]) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            TerminalCursorErase.erase(pixels: buffer.baseAddress!, bytesPerRow: width * 4,
                                      rect: .init(x: 0, y: 0, width: width, height: height), background: background)
        }
    }

    @Test func aBlockCursorKeepsItsGlyphInTheCursorsColour() {
        // A block in the cursor colour with the glyph drawn in the background
        // colour (Ghostty's cursor text), one edge pixel half covered.
        var pixels = cell(fill: cursor)
        for y in 4..<16 { set(&pixels, 4, y, background) }
        set(&pixels, 5, 10, (118, 118, 120))
        erase(&pixels)
        #expect(get(pixels, 0, 0) == background)
        #expect(get(pixels, 9, 19) == background)
        #expect(get(pixels, 4, 8) == cursor)
        let half = get(pixels, 5, 10)
        #expect(half.0 > 100 && half.0 < 140)
    }

    @Test func aHollowCursorLosesItsOutlineNotItsGlyph() {
        // Unfocused: a one-pixel outline around the cell, the glyph inside in
        // the foreground colour.
        var pixels = cell(fill: background)
        for x in 0..<width { set(&pixels, x, 0, cursor); set(&pixels, x, height - 1, cursor) }
        for y in 0..<height { set(&pixels, 0, y, cursor); set(&pixels, width - 1, y, cursor) }
        for y in 4..<16 { set(&pixels, 4, y, cursor) }
        erase(&pixels)
        #expect(get(pixels, 0, 5) == background)
        #expect(get(pixels, 5, 0) == background)
        #expect(get(pixels, 9, 19) == background)
        #expect(get(pixels, 4, 8) == cursor)
    }

    @Test func aCellWithNoCursorDrawnIsLeftAlone() {
        // The blink's off phase: just the glyph.
        var pixels = cell(fill: background)
        for y in 4..<16 { set(&pixels, 4, y, cursor) }
        let before = pixels
        erase(&pixels)
        #expect(pixels == before)
    }

    /// Round 11 N5: the cell Ghostty reported was half a cell off the block
    /// it drew, so the block stayed in the saved frame (a grey cell behind
    /// the X). The erase finds the block within a cell of the reported rect.
    @Test func aBlockHalfACellFromTheReportedCellIsStillErased() {
        let wide = 30
        var pixels = [UInt8](repeating: 255, count: wide * height * 4)
        func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let i = (y * wide + x) * 4
            pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2
        }
        func read(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * wide + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        for y in 0..<height { for x in 0..<wide { put(x, y, background) } }
        // The block in cells 10..<20, an X-like stroke of background inside.
        for y in 0..<height { for x in 10..<20 { put(x, y, cursor) } }
        for y in 4..<16 { put(14, y, background) }
        pixels.withUnsafeMutableBufferPointer { buffer in
            TerminalCursorErase.erase(pixels: buffer.baseAddress!, bytesPerRow: wide * 4,
                                      rect: .init(x: 5, y: 0, width: width, height: height), background: background,
                                      bounds: (wide, height))
        }
        #expect(read(10, 0) == background)
        #expect(read(19, 19) == background)
        #expect(read(17, 2) == background)
        #expect(read(14, 8) == cursor)
    }
}
