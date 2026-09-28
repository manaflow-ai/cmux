import Foundation

/// A block and the screen rows it occupies.
public struct TerminalCodeBlockAnchor: Sendable, Equatable {
    public let block: TerminalCodeBlock
    /// Grid rows from the top of the viewport, inclusive.
    public let rows: ClosedRange<Int>

    public init(block: TerminalCodeBlock, rows: ClosedRange<Int>) {
        self.block = block
        self.rows = rows
    }
}

/// Decides which blocks are on screen and where.
///
/// Sources in priority order: blocks a process offered explicitly, fences
/// from the agent's transcript, then literal fences drawn on screen. When
/// two claim overlapping rows the higher-priority one keeps them.
public struct TerminalCodeBlockAnchorResolver: Sendable {
    public init() {}

    /// Anchors for the current screen, top to bottom.
    ///
    /// - Parameters:
    ///   - rows: The viewport, one string per grid row.
    ///   - offered: Blocks offered through `cmux code-block`, oldest first.
    ///   - transcript: Fences from the pane's agent transcript, oldest first.
    public func anchors(
        rows: [String],
        offered: [TerminalCodeBlock] = [],
        transcript: [AgentTranscriptCodeBlockExtractor.Entry] = []
    ) -> [TerminalCodeBlockAnchor] {
        let locator = TerminalCodeBlockScreenLocator()
        var claimed: [TerminalCodeBlockAnchor] = []

        func claim(_ anchor: TerminalCodeBlockAnchor) {
            guard !claimed.contains(where: { $0.rows.overlaps(anchor.rows) }) else { return }
            claimed.append(anchor)
        }

        for block in offered.reversed() {
            let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let range = locator.locate(lines, in: rows) {
                claim(TerminalCodeBlockAnchor(block: block, rows: range))
            }
        }
        for entry in transcript.reversed() {
            if let range = locator.locate(entry.fence.body, in: rows) {
                claim(TerminalCodeBlockAnchor(block: entry.block, rows: range))
            }
        }
        let cleaner = TerminalCodeBlockText()
        for fence in TerminalCodeFenceParser().fences(inLines: rows, includeUnclosed: false) {
            guard let closing = fence.closingLine else { continue }
            let text = cleaner.copyText(for: fence)
            guard !text.isEmpty else { continue }
            let block = TerminalCodeBlock(text: text, language: fence.infoString, origin: .screen)
            claim(TerminalCodeBlockAnchor(block: block, rows: fence.openingLine...closing))
        }
        return claimed.sorted { $0.rows.lowerBound < $1.rows.lowerBound }
    }

    /// The row the hover pill sits on: the blank row just above the block
    /// when there is one, so the pill never covers the block's first line;
    /// otherwise the first row itself.
    public func pillRow(for anchor: TerminalCodeBlockAnchor, rows: [String]) -> Int {
        let above = anchor.rows.lowerBound - 1
        guard above >= 0, above < rows.count,
              rows[above].trimmingCharacters(in: .whitespaces).isEmpty else {
            return anchor.rows.lowerBound
        }
        return above
    }

    /// The anchor under a grid row, if any.
    public func anchor(atRow row: Int, in anchors: [TerminalCodeBlockAnchor]) -> TerminalCodeBlockAnchor? {
        anchors.first { $0.rows.contains(row) }
    }
}
