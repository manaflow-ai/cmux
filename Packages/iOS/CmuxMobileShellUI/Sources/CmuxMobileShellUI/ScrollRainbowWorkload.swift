#if canImport(UIKit) && DEBUG
import Foundation

/// Deterministic terminal output for the iOS scroll investigation.
///
/// Each row has a distinct 24-bit background and carries its row number in the
/// foreground. The row identity makes a one-frame viewport jump visible in a
/// recording, while the optional stream appends output without changing the
/// scroll mechanics or renderer code used by the app.
struct ScrollRainbowWorkload {
    let columns: Int
    let initialRowCount: Int
    private(set) var nextRow: Int

    init(columns: Int, initialRowCount: Int) {
        self.columns = max(columns, 1)
        self.initialRowCount = max(initialRowCount, 1)
        self.nextRow = max(initialRowCount, 1)
    }

    func initialOutput() -> Data {
        output(rows: 0..<initialRowCount)
    }

    mutating func nextOutput(rowCount: Int) -> Data {
        let count = max(rowCount, 1)
        let start = nextRow
        nextRow += count
        return output(rows: start..<nextRow)
    }

    private func output(rows: Range<Int>) -> Data {
        var text = String()
        text.reserveCapacity(rows.count * (columns + 48))
        for row in rows {
            text.append(line(row: row))
        }
        return Data(text.utf8)
    }

    private func line(row: Int) -> String {
        // Multiplication by the golden-ratio constant spreads adjacent rows
        // through RGB space, avoiding the repeating short palette a simple
        // row % 256 scheme would produce.
        let hash = UInt32(truncatingIfNeeded: row) &* 2_654_435_761
        let red = 42 + Int((hash >> 16) & 0xBF)
        let green = 42 + Int((hash >> 8) & 0xBF)
        let blue = 42 + Int(hash & 0xBF)
        let luminance = (299 * red + 587 * green + 114 * blue) / 1000
        let foreground = luminance > 150 ? (0, 0, 0) : (255, 255, 255)
        let marker = String(
            format: "row %05d  codex output  #%02x%02x%02x",
            row,
            red,
            green,
            blue
        )
        let visible = String(marker.prefix(columns))
        let padding = String(repeating: " ", count: max(0, columns - visible.count))
        return "\u{1b}[48;2;\(red);\(green);\(blue)m"
            + "\u{1b}[38;2;\(foreground.0);\(foreground.1);\(foreground.2)m"
            + visible
            + padding
            + "\u{1b}[0m\r\n"
    }
}
#endif
