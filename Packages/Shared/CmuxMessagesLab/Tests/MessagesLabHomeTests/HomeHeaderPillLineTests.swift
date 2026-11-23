import AppKit
import Testing
@testable import MessagesLabHome

/// User 2026-11-20 ("get rid of this"): a control on the name pill's line ("This Mac + Cloud fork")
/// covered the pill's title ("workspace-1005"). The pill's line holds the pill and the faces of who
/// else has the chat open, nothing else; the title and its chevron fit inside the pill; the faces
/// start clear after it.
@MainActor struct HomeHeaderPillLineTests {
    private static let titles = ["Chief", "workspace-1005", "A Chief with a much longer name"]

    private func header(_ title: String, width: CGFloat = 1000) -> PaneHeaderView {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        header.title = title
        header.layoutSubtreeIfNeeded()
        header.layout()
        return header
    }

    /// The title's ink and the chevron, side by side: the pill (Messages' measured width, tighter
    /// than AppKit's own glass padding) still holds them with room to spare.
    @Test(arguments: titles)
    func theTitleAndChevronFitInsideThePill(title: String) throws {
        let header = header(title)
        let font = try #require(header.pill.font)
        let ink = (title as NSString).size(withAttributes: [.font: font]).width
        let chevron = header.pill.image?.size.width ?? 0
        let content = ink + 4 + chevron
        #expect(content <= header.pill.frame.width - 8,
                "the \"\(title)\" pill is \(header.pill.frame.width) pt wide; its title and chevron take \(content) pt")
    }

    /// a1285 (2026-11-20): the pill took Messages' measured width, about 8 pt under what the button
    /// itself needs for its bold title, its chevron and its glass padding, so a long name such as
    /// "workspace-1005" was cut. The pill is at least as wide as AppKit sizes that button.
    @Test(arguments: titles)
    func thePillIsAsWideAsItsButtonNeeds(title: String) {
        let header = header(title)
        let needs = header.pill.intrinsicContentSize.width
        #expect(header.pill.frame.width >= needs - 0.5,
                "the \"\(title)\" pill is \(header.pill.frame.width) pt wide; its button needs \(needs) pt")
    }

    @Test(arguments: titles)
    func theFacesStartClearAfterThePill(title: String) {
        let header = header(title)
        header.faces = [PaneHeaderFace(initial: "A", color: .systemBlue), PaneHeaderFace(initial: "B", color: .systemGreen)]
        header.layout()
        #expect(!header.facesView.isHidden)
        #expect(header.facesView.frame.minX >= header.pill.frame.maxX + PaneHeaderView.facesGap - 0.5,
                "the faces start at \(header.facesView.frame.minX), over the \"\(title)\" pill, which ends at \(header.pill.frame.maxX)")
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
