#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// The find highlight is part of the page: it stays on its match's cells while the page scrolls,
/// with no caller reporting the scroll (it floated: a scroll that no call site redrew left the
/// highlight at the rows it was laid over).
@MainActor
@Suite struct TerminalFindHighlightFollowsScrollTests {
    private let cell = CGSize(width: 8, height: 16)

    private func page() -> (UIScrollView, TerminalFindController) {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        scroll.contentSize = CGSize(width: 320, height: 100 * cell.height)
        let rows = (0..<100).map { $0 == 5 ? "xx needle" : $0 == 90 ? "yy needle" : "plain" }
        let finder = TerminalFindController()
        finder.readRows = { (rows, Array(repeating: false, count: rows.count), 0, 80) }
        finder.rectFor = { [cell] point in
            CGRect(x: CGFloat(point.column) * cell.width, y: CGFloat(point.row) * cell.height, width: cell.width, height: cell.height)
        }
        finder.highlightHost = { scroll }
        finder.drawnRows = { [cell] in
            let first = max(0, Int(scroll.contentOffset.y / cell.height) - 10)
            let last = min(100, Int((scroll.contentOffset.y + scroll.bounds.height) / cell.height) + 10)
            return first..<last
        }
        return (scroll, finder)
    }

    @Test func theHighlightCoversItsCellAfterTheOffsetChanges() async throws {
        let (scroll, finder) = page()
        finder.search("needle")
        await finder.searchTask?.value
        // Nearest the prompt is selected: row 90, which is far below the first screen.
        #expect(finder.results.matches.map(\.row) == [5, 90])
        let before = finder.highlightedRects
        let row5 = CGRect(x: 3 * cell.width, y: 5 * cell.height, width: 6 * cell.width, height: cell.height)
        #expect(before.contains { $0.intersects(row5) })

        // The page scrolls to row 90 with nobody telling the finder.
        scroll.contentOffset.y = 85 * cell.height
        let row90 = CGRect(x: 3 * cell.width, y: 90 * cell.height, width: 6 * cell.width, height: cell.height)
        let after = finder.highlightedRects
        #expect(after.contains { $0.contains(row90.insetBy(dx: 1, dy: 1)) })
    }
}
#endif
