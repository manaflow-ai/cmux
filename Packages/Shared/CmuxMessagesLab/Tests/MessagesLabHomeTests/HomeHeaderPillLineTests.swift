import AppKit
import Testing
@testable import MessagesLabHome

/// User 2026-11-20 ("get rid of this"): a control on the name pill's line ("This Mac + Cloud fork")
/// covered the end of the pill's title ("workspace-1005"). The pill is as wide as its title and
/// chevron need, and what sits after it on its line (the faces of who else has the chat open)
/// starts clear of it.
@MainActor struct HomeHeaderPillLineTests {
    private static let titles = ["Chief", "workspace-1005", "A Chief with a much longer name"]

    private func header(_ title: String, width: CGFloat = 1000) -> PaneHeaderView {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        header.title = title
        header.layoutSubtreeIfNeeded()
        header.layout()
        return header
    }

    @Test(arguments: titles)
    func thePillIsAsWideAsItsTitleNeeds(title: String) {
        let header = header(title)
        let needed = header.pill.intrinsicContentSize.width
        #expect(header.pill.frame.width >= needed - 0.5,
                "the \"\(title)\" pill is \(header.pill.frame.width) pt wide; its title and chevron need \(needed) pt, so they run past it")
    }

    @Test(arguments: titles)
    func theFacesStartClearOfThePillsTitle(title: String) {
        let header = header(title)
        header.faces = [PaneHeaderFace(initial: "A", color: .systemBlue), PaneHeaderFace(initial: "B", color: .systemGreen)]
        header.layout()
        #expect(!header.facesView.isHidden)
        let titleEnd = header.pill.frame.minX + max(header.pill.frame.width, header.pill.intrinsicContentSize.width)
        #expect(header.facesView.frame.minX >= titleEnd + PaneHeaderView.facesGap - 0.5,
                "the faces start at \(header.facesView.frame.minX), over the \"\(title)\" pill's title, which ends at \(titleEnd)")
    }

    /// The pill's line holds the pill and the faces, nothing else: no control drawn over the name.
    @Test func thePillsLineHoldsOnlyThePillAndTheFaces() {
        let header = header("workspace-1005")
        let line = CGRect(x: 0, y: header.pill.frame.minY, width: header.bounds.width, height: header.pill.frame.height)
        let others = header.subviews.filter {
            !$0.isHidden && $0.frame.intersects(line) && ![header.pill, header.pillBacking, header.facesView, header.avatar].contains($0)
        }
        #expect(others.isEmpty, "on the name pill's line: \(others)")
    }
}
