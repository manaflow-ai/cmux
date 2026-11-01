import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19245, a shot of the "Chief TUI + fast iteration" hover card: "alignment here looks bad.
/// design not very good either, not showing enough details per each". The workspace hover card is one
/// grid: the header's icon and every tab row's icon center on one x, the header's name, every tab's title
/// and detail line, "Show N more" and "Show details" start on one text x, the tab rows keep one pitch,
/// and every tab row shows its detail line (its place, state and time; its kind when it has none).
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceHoverCardGridTests {
    private struct Mounted {
        let window: NSWindow
        let card: WorkspaceHoverCardView
    }

    private static func mount() -> Mounted {
        _ = NSApplication.shared
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardFixture.content, now: WorkspaceHoverCardFixture.now)
        card.tabList.configure(title: WorkspaceHoverCardFixture.title, tabs: WorkspaceHoverCardFixture.tabs)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        window.contentView?.addSubview(card)
        card.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: card.fittingSize)
        card.layoutSubtreeIfNeeded()
        card.tabList.layoutSubtreeIfNeeded()
        for view in Self.descendants(of: card) { view.layoutSubtreeIfNeeded() }
        return Mounted(window: window, card: card)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func shown(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

    /// Where a label's text starts, in the card: its alignment rect leaves out the label's own padding.
    private static func textX(_ label: ChromeLabel, in card: NSView) -> CGFloat {
        let rect = label.alignmentRect(forFrame: label.frame)
        return card.convert(NSPoint(x: rect.minX, y: rect.minY), from: label.superview).x
    }

    /// Where a text button's title starts, in the card: its cell's title rect.
    private static func textX(_ button: NSButton, in card: NSView) throws -> CGFloat {
        let cell = try #require(button.cell)
        return card.convert(cell.titleRect(forBounds: button.bounds).origin, from: button).x
    }

    /// `view`'s frame in the card, top down (y grows downward whether or not the card is flipped).
    private static func frame(_ view: NSView, in card: NSView) -> CGRect {
        let rect = card.convert(view.bounds, from: view)
        return card.isFlipped ? rect : CGRect(x: rect.minX, y: card.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private struct Row {
        let view: WorkspaceTabHoverCardRow
        let icon: NSImageView
        let title: ChromeLabel
        let detail: ChromeLabel?
    }

    private static func rows(in card: WorkspaceHoverCardView) throws -> [Row] {
        let views = descendants(of: card.tabList).compactMap { $0 as? WorkspaceTabHoverCardRow }.filter(shown)
            .sorted { frame($0, in: card).minY < frame($1, in: card).minY }
        return try views.map { row in
            let icon = try #require(descendants(of: row).compactMap { $0 as? NSImageView }.first(where: shown), "a tab row has no icon")
            let labels = descendants(of: row).compactMap { $0 as? ChromeLabel }.filter { shown($0) && !$0.stringValue.isEmpty }
                .sorted { frame($0, in: card).minY < frame($1, in: card).minY }
            let title = try #require(labels.first, "a tab row has no title")
            let detail = labels.dropFirst().first { frame($0, in: card).minY >= frame(title, in: card).maxY - 1 }
            return Row(view: row, icon: icon, title: title, detail: detail)
        }
    }

    @Test func everyIconSharesOneColumnAndEveryTextOneEdge() throws {
        let mounted = Self.mount()
        defer { mounted.window.closeAfterTest() }
        let card = mounted.card
        let header = try #require(Self.descendants(of: card).compactMap { $0 as? HoverCardIconView }.first(where: Self.shown),
                                  "the header has no icon")
        let name = try #require(Self.descendants(of: card).compactMap { $0 as? ChromeLabel }
            .first { Self.shown($0) && $0.stringValue == WorkspaceHoverCardFixture.title }, "the header has no name")
        let iconX = Self.frame(header, in: card).midX
        let textX = Self.textX(name, in: card)
        let rows = try Self.rows(in: card)
        try #require(rows.count >= 4, "the card lists \(rows.count) tabs")
        for row in rows {
            let x = Self.frame(row.icon, in: card).midX
            #expect(abs(x - iconX) <= 0.5, "\"\(row.title.stringValue)\": its icon centers at x \(x), the header's at \(iconX)")
            let titleX = Self.textX(row.title, in: card)
            #expect(abs(titleX - textX) <= 0.5, "\"\(row.title.stringValue)\": its title starts at x \(titleX), the name at \(textX)")
            if let detail = row.detail {
                let detailX = Self.textX(detail, in: card)
                #expect(abs(detailX - textX) <= 0.5, "\"\(row.title.stringValue)\": its detail starts at x \(detailX), the name at \(textX)")
            }
        }
        let more = try #require(Self.descendants(of: card.tabList).compactMap { $0 as? NSButton }.first(where: Self.shown),
                                "13 tabs show no Show more")
        let moreX = try Self.textX(more, in: card)
        #expect(abs(moreX - textX) <= 0.5, "\"\(more.title)\" starts at x \(moreX), the name at \(textX)")
        try #require(Self.shown(card.detailsToggle), "the card has details but no Show details")
        let toggleX = try Self.textX(card.detailsToggle, in: card)
        #expect(abs(toggleX - textX) <= 0.5, "\"\(card.detailsToggle.title)\" starts at x \(toggleX), the name at \(textX)")
    }

    @Test func tabRowsKeepOnePitchAndEachShowsItsDetailLine() throws {
        let mounted = Self.mount()
        defer { mounted.window.closeAfterTest() }
        let card = mounted.card
        let rows = try Self.rows(in: card)
        try #require(rows.count >= 4, "the card lists \(rows.count) tabs")
        let tops = rows.map { Self.frame($0.view, in: card).minY }
        let pitches = zip(tops.dropFirst(), tops).map { $0 - $1 }
        for pitch in pitches {
            #expect(abs(pitch - pitches[0]) <= 0.5, "tab row pitches \(pitches) are uneven")
        }
        for row in rows {
            let detail = row.detail?.stringValue ?? ""
            #expect(!detail.isEmpty, "\"\(row.title.stringValue)\" shows no detail line")
            // The icon sits on its title's line (the middle of its capitals), not between the two lines.
            let font = try #require(row.title.font)
            let titleFrame = Self.frame(row.title, in: card)
            let capMiddle = titleFrame.minY + row.title.firstBaselineOffsetFromTop - font.capHeight / 2
            let iconMiddle = Self.frame(row.icon, in: card).midY
            #expect(abs(iconMiddle - capMiddle) <= 1, "\"\(row.title.stringValue)\": its icon's middle is \(iconMiddle - capMiddle) pt off its title's capitals")
        }
    }
}
