import AppKit
@testable import CmuxNextDesign
import Testing

/// A label that keeps a name on one line draws its hyphens as non-breaking hyphens (U+2011; the Chief
/// Settings diagnostics, "claude-sr2-pipe"). Selected and copied, the name pastes with plain hyphens,
/// so it matches the name as typed.
@MainActor @Suite struct LabelCopyHyphenTests {
    @Test func aNonBreakingHyphenCopiesAsAHyphen() throws {
        let shape = LabelText.Shape(lines: 0, wraps: true, lineBreak: .byWordWrapping, alignment: .natural, tightens: false,
                                    truncatesLastVisibleLine: false, strategy: [])
        let text = NSAttributedString(string: "Last turn: claude\u{2011}sr2\u{2011}pipe", attributes: [.font: Typography.caption])
        let view = LabelSelectionView(text: text, shape: shape, size: NSSize(width: 300, height: 40))
        view.selectAll(nil)
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-label-copy-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(view.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string) == "Last turn: claude-sr2-pipe")
    }
}
