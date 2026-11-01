import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19245, a shot of the "Chief TUI + fast iteration" hover card: "alignment here looks bad.
/// design not very good either, not showing enough details per each". The workspace hover card is one
/// grid: the header's icon, every tab row's icon and the Show details chevron center on one x, the header's
/// name, every tab's title and detail line and "Show details" start on one text x, the tab rows keep one pitch,
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
        card.configureTabs(title: WorkspaceHoverCardFixture.title, tabs: WorkspaceHoverCardFixture.tabs, now: WorkspaceHoverCardFixture.now)
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
        // Show details (Leo 2026-11-01's row-styled disclosure): its words on the text column, its chevron
        // on the icon column. Every tab is listed (no Show N more since Leo's change).
        try #require(Self.shown(card.detailsToggle), "the card has details but no Show details")
        let words = try #require(Self.descendants(of: card.detailsToggle).compactMap { $0 as? ChromeLabel }.first)
        let toggleX = Self.textX(words, in: card)
        #expect(abs(toggleX - textX) <= 0.5, "\"\(words.stringValue)\" starts at x \(toggleX), the name at \(textX)")
        let chevron = try #require(Self.descendants(of: card.detailsToggle).compactMap { $0 as? NSImageView }.first)
        let chevronX = Self.frame(chevron, in: card).midX
        #expect(abs(chevronX - iconX) <= 0.5, "the Show details chevron centers at x \(chevronX), the header icon at \(iconX)")
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

    /// The owner, on msg 19245's gallery: "every detail line truncates to noise". With all 13 tabs listed,
    /// each tab row's detail line shows its whole state word and time, keeps its place's last path component
    /// (or its host), and draws unclipped; the card stays within its widest.
    @Test func everyTabsDetailKeepsItsStateTimeAndPlace() throws {
        let mounted = Self.mount()
        defer { mounted.window.closeAfterTest() }
        let card = mounted.card
        card.frame.size = card.fittingSize
        card.layoutSubtreeIfNeeded()
        for view in Self.descendants(of: card) { view.layoutSubtreeIfNeeded() }
        #expect(card.frame.width <= WorkspaceHoverCardView.maxCardWidth + 0.5, "the card is \(card.frame.width) pt wide")
        let rows = Self.descendants(of: card.tabList).compactMap { $0 as? WorkspaceTabHoverCardRow }.filter { !$0.isHidden }
            .sorted { Self.frame($0, in: card).minY < Self.frame($1, in: card).minY }
        let tabs = WorkspaceHoverCardFixture.tabs
        try #require(rows.count == tabs.count, "\(rows.count) rows for \(tabs.count) tabs")
        for (row, tab) in zip(rows, tabs) {
            let labels = Self.descendants(of: row).compactMap { $0 as? ChromeLabel }.filter { Self.shown($0) && !$0.stringValue.isEmpty }
                .sorted { $0.frame.minY < $1.frame.minY }
            let detail = try #require(labels.dropFirst().first, "\(tab.title) shows no detail line")
            let text = detail.stringValue
            let now = WorkspaceHoverCardFixture.now
            for field in [WorkspaceTabHoverCardStyle.Field.state, .time] {
                if let word = WorkspaceTabHoverCardLine.text(field, of: tab, now: now) {
                    #expect(text.contains(word), "\(tab.title): \"\(text)\" lost \"\(word)\"")
                }
            }
            if let place = tab.kind == .browser ? tab.host : tab.folder, let last = place.split(separator: "/").last {
                #expect(text.contains(last), "\(tab.title): \"\(text)\" lost its place's end \"\(last)\"")
            }
            // Frame terms (`naturalSize` includes the label's padding): a frame short of it clips the text.
            for label in [labels[0], detail] {
                #expect(label.naturalSize.width <= label.frame.width + 0.5,
                        "\(tab.title): \"\(label.stringValue)\" is clipped (\(label.naturalSize.width) in \(label.frame.width))")
            }
        }
    }

    /// A blank page reads "New Tab", with no "about:blank" or "Blank page".
    @Test func aBlankPageReadsNewTab() {
        let line = WorkspaceTabHoverCardLine(SidebarTab(id: TabID("b"), title: "about:blank", kind: .browser), style: .standard,
                                             now: WorkspaceHoverCardFixture.now)
        #expect(WorkspaceTabHoverCardLine.title(SidebarTab(id: TabID("b"), title: "about:blank", kind: .browser)) == Strings.hoverCardNewTab)
        #expect(line.detail == Strings.hoverCardKindBrowser)
    }

    /// The place shortens from its middle and keeps its last path component.
    @Test func aLongPlaceKeepsItsLastComponent() {
        let font = Typography.caption
        let fitted = WorkspaceTabHoverCardLine.fit(place: "~/fun/cmux/Packages/macOS/CmuxNext/Sources", width: 90, font: font)
        #expect(fitted.hasSuffix("/Sources") && fitted.contains("…"), "\(fitted)")
        #expect(WorkspaceTabHoverCardLine.fit(place: "~/fun", width: 200, font: font) == "~/fun")
    }
}
