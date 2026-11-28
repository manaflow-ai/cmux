import AppKit

/// Text sizes as the card's labels draw them: the same NSTextFieldCell
/// configuration measures and renders, so a measured row never clips.
struct AgentQuestionTextMeasure {
    private let cell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.wraps = true
        cell.isScrollable = false
        cell.lineBreakMode = .byWordWrapping
        cell.truncatesLastVisibleLine = false
        return cell
    }()

    /// Height of `text` wrapped to `width`.
    func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        cell.font = font
        cell.stringValue = text
        cell.wraps = true
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// Width of `text` on one line.
    func width(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        cell.font = font
        cell.stringValue = text
        cell.wraps = false
        return ceil(cell.cellSize.width)
    }

    /// Height of one line of `font`.
    func lineHeight(_ font: NSFont) -> CGFloat { height("Ag", font: font, width: 1000) }
}
