import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// Leo 2026-11-07, on the tab hover card and the + beside the tabs: "is the length of it based off of
/// anything? ... Or should we have it just be the same size of the, like max width of a tab?"; "Does
/// this need so many symbols? Like the file fold, the folder icon for the projects, and then that, like,
/// cursor thing for the bottom metadata row?"; "decrease the size of the tab area plus button, or
/// increase the size of the new workspace area button? Or I guess, like, probably do something in the
/// middle". The card is a tab's widest, grows only for a long path, and has one glyph, the title's;
/// the tab row's + and the sidebar's New Workspace + are one size, between the two they were.
@MainActor @Suite(.serialized) struct TabHoverCardProportionsTests {
    private func card(subtitle: String) -> TabHoverCardView {
        var item = TabItem(id: TabID("agent"), title: "claude-sr2-coord", subtitle: subtitle, icon: .icon(.agentChat))
        item.hover = TabHoverFacts(kind: .agentChat, activity: .idle, since: Date().addingTimeInterval(-22), model: "claude-opus-5-5")
        let card = TabHoverCardView()
        card.configure(.tab(item))
        card.setThumbnailVisible(false)
        card.layoutSubtreeIfNeeded()
        return card
    }

    @Test func theCardIsAsWideAsATabAtItsWidest() {
        let width = card(subtitle: "~/Projects").fittingSize.width
        #expect(abs(width - Metrics.tabMaxWidth) < 0.5, "card \(width) pt, a tab at its widest \(Metrics.tabMaxWidth) pt")
    }

    @Test func aLongPathGrowsTheCardOnlyToItsCap() {
        let long = card(subtitle: "~/Projects/checkouts/cmux/lane--tab-hover-card-proportions/Packages/macOS").fittingSize.width
        #expect(long > Metrics.tabMaxWidth + 0.5, "a long path kept the card at \(long) pt")
        #expect(long <= TabHoverCardView.maxWidth + 0.5, "a long path grew the card to \(long) pt, past its cap")
        let huge = card(subtitle: String(repeating: "/very-long-folder-name", count: 40)).fittingSize.width
        #expect(abs(huge - TabHoverCardView.maxWidth) < 0.5, "the cap is \(TabHoverCardView.maxWidth) pt, the card \(huge) pt")
    }

    @Test func onlyTheTitleHasAGlyph() {
        let card = card(subtitle: "~/Projects")
        #expect(!card.kindIcon.isHidden, "the title lost the tab's own glyph")
        #expect(card.reportedLines.count >= 3, "lines \(card.reportedLines)")
        for row in [card.placeRow, card.statusRow, card.detailRow, card.memoryRow] where !row.isHidden {
            #expect(row.icon.isHidden, "the row \(row.shownText) still draws an icon")
        }
    }

    @Test func theTabRowsPlusAndTheSidebarsPlusAreOneSize() throws {
        _ = NSApplication.shared
        let tabPlus = NewTabButtonView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        tabPlus.layoutSubtreeIfNeeded()
        tabPlus.layout()
        let shape = try #require(tabPlus.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let tabExtent = try #require(shape.path).boundingBoxOfPath.width + shape.lineWidth

        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        sidebar.layoutSubtreeIfNeeded()
        let image = try #require(sidebar.newButton.image)
        let sidebarExtent = Self.inkWidth(image)

        // Before: the tab row's + reached 10 pt plus its 1.4 pt stroke, the sidebar's about 8 pt.
        #expect(abs(tabExtent - sidebarExtent) <= 0.5, "tab row + \(tabExtent) pt, sidebar + \(sidebarExtent) pt")
        #expect(tabExtent > 9 && tabExtent < 11.4, "the + is \(tabExtent) pt, not between the two it replaces")
    }

    @Test func theTabRowsChevronMatchesItsPlus() throws {
        let chooser = PaneTypeMenuButton(frame: NSRect(x: 0, y: 0, width: 16, height: 24))
        let glyph = try #require(chooser.subviews.first as? TitlebarBandButton)
        #expect(glyph.symbolPointSize?() == Metrics.addMenuChevronPointSize)
        #expect(Metrics.addMenuChevronPointSize < Metrics.smallIconSize, "the chevron is still the 12 pt one beside a smaller +")
    }

    /// The width in points of what `image` draws (its non-clear columns at 4x).
    private static func inkWidth(_ image: NSImage) -> CGFloat {
        let scale: CGFloat = 4
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1
        for x in 0..<width {
            for y in 0..<height where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                break
            }
        }
        return maxX < minX ? 0 : CGFloat(maxX - minX + 1) / scale
    }
}
