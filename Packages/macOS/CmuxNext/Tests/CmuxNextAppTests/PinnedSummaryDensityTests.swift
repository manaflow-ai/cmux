import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-03: "make sure size of the pinned summary thing reflect size of ui compactness i chose".
///
/// A pinned workspace's row and the hover card it opens are sized by the sidebar's derived tokens
/// (``SidebarRowTokens``, docs/cmux-next/derived-sizing.md) at every `sidebar.density` × `sidebar.textSize`:
/// the row is as tall as a workspace row, with the same title font and the same icon side; the card's
/// padding, icon column, text, widths, tab rows and disclosure equal ``SidebarRowTokens/hoverCard``; and every
/// size grows with the text size and never shrinks from compact to comfortable. Each case prints a
/// `PINNEDSIZE|` line so a fleet log shows the measured numbers.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedSummaryDensityTests {
    nonisolated struct Setting: CustomStringConvertible, Sendable {
        let density: SidebarDensity
        let textSize: SidebarTextSize
        var description: String { "\(density.rawValue)/\(textSize.rawValue)" }
    }

    nonisolated static let settings: [Setting] = SidebarDensity.allCases.flatMap { density in
        SidebarTextSize.allCases.map { Setting(density: density, textSize: $0) }
    }

    private static let pinnedID = WorkspaceID("ws-pinned-size")
    private static let listedID = WorkspaceID("ws-listed-size")
    private static let item = LayoutItem(id: LayoutItemID("itm_pin_size"), ref: .workspace("local:ws-pinned-size"))

    /// A 32 px square favicon: the pinned row and the workspace row draw it at their own icon side.
    static let favicon: SidebarFavicon = {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return SidebarFavicon(context.makeImage()!)
    }()

    /// A shell with no detail line (one row tall), a page, and a Codex chat whose model is its detail line (two rows
    /// tall, as in `WorkspaceHoverCardUnifiedStyleTests`).
    static var pinned: SidebarWorkspace {
        var chat = SidebarTab(id: TabID("pin-chat"), title: "chat", kind: .agentChat, brand: "codex")
        chat.model = "gpt-6-astra"
        return SidebarWorkspace(id: pinnedID, title: "Cloud Chief rebuild with a long name that wraps in the card",
                                tabs: [SidebarTab(id: TabID("pin-shell"), title: "shell"),
                                       SidebarTab(id: TabID("pin-docs"), title: "docs", kind: .browser), chat])
    }

    /// Runs `body` with the sidebar at `setting`, on the compact app density.
    static func at<T>(_ setting: Setting, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.density = setting.density
        DesignSettings.shared.sidebarSections.textSize = setting.textSize
        defer { DesignSettings.shared.sidebarSections = saved }
        return try DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) { try body() }
    }

    struct Measured {
        var pinnedRowHeight: CGFloat
        var pinnedTitle: CGFloat
        var pinnedGlyph: CGFloat
        var listRowHeight: CGFloat
        var listTitle: CGFloat
        var listGlyph: CGFloat
        var cardPadding: CGFloat
        var cardIcon: CGFloat
        var cardTitle: CGFloat
        var cardCaption: CGFloat
        var cardWidth: CGFloat
        var cardMinWidth: CGFloat
        var tabRowHeight: CGFloat
        /// Whether the measured tab row draws a detail line (a two-line row); the fixture's first tab has none.
        var tabHasDetail: Bool
        /// The chat tab's row, which has a detail line (its model): its height and whether the line shows.
        var detailTabRowHeight: CGFloat
        var detailTabHasDetail: Bool
        var tabTitle: CGFloat
        var tabIcon: CGFloat
        var disclosureHeight: CGFloat
    }

    /// The real pinned row in a list's Pinned block beside a workspace row, and the card the pinned row opens.
    static func measure(_ setting: Setting) throws -> Measured {
        try at(setting) {
            _ = NSApplication.shared
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let pinnedSection = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarDocStore.pinnedSection)), nodes: [])
            let listed = SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: listedID, title: "api"))])
            let model = SidebarModel(sections: [pinnedSection, listed], activeWorkspaceID: nil)
            let list = SidebarListView(model: model)
            var info = SidebarItemInfo(title: pinned.title, symbol: "globe")
            info.favicon = favicon
            info.leadingPin = true
            info.workspace = pinnedID
            info.workspaceRow = pinned
            let section = SidebarLayoutDocument.pinnedSection(items: [item])
            list.blocks = SidebarListBlocks(sections: [section.id.rawValue: section], infos: [item.id: info], collapsed: [],
                                            look: .quiet, metrics: .standard, drawsLines: false, appHeights: [:])
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            window.contentView = list
            list.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let row = try #require(list.blockRegions.lazy.compactMap { $0.itemViews[item.id] }.first, "\(setting): no pinned row")
            row.layoutSubtreeIfNeeded()
            row.layout()
            let listRow = try #require(list.rowViews[.workspace(listedID)] as? WorkspaceRowView, "\(setting): no list row")
            let icon = SidebarIconView(frame: NSRect(x: 0, y: 0, width: SidebarStyle.iconColumnBox, height: SidebarStyle.iconColumnBox))
            icon.configure(icon: .favicon(favicon))
            icon.layoutSubtreeIfNeeded()
            let listGlyph = icon.subviews.compactMap { ($0 as? NSImageView)?.image }.first?.size.width ?? 0

            let card = WorkspaceHoverCardView()
            card.configure(.make(pinned, machine: nil, now: Date()))
            card.configureTabs(title: pinnedID.rawValue, tabs: pinned.tabs, machine: nil)
            // The card's widest and narrowest: its fitting size pulled wide, then narrow, against its own required width
            // limits (the panel sizes it between them). The pull outranks the labels' hugging, as the panel's 999 edges do.
            func fittingWidth(pulledTo width: CGFloat) -> CGFloat {
                let pull = card.widthAnchor.constraint(equalToConstant: width)
                pull.priority = .init(999)
                pull.isActive = true
                defer { pull.isActive = false }
                return card.fittingSize.width
            }
            let widest = fittingWidth(pulledTo: 2000), narrowest = fittingWidth(pulledTo: 0)
            card.frame.size = card.fittingSize
            card.layoutSubtreeIfNeeded()
            let tab = try #require(card.tabList.rowViews.first, "\(setting): the card drew no tab row")
            tab.layout()
            let chatIndex = try #require(pinned.tabs.firstIndex { $0.id == TabID("pin-chat") })
            try #require(card.tabList.rowViews.count > chatIndex, "\(setting): the card drew no row for the chat tab")
            let chatRow = card.tabList.rowViews[chatIndex]
            chatRow.layout()
            let measured = Measured(
                pinnedRowHeight: row.bounds.height, pinnedTitle: row.title.font?.pointSize ?? 0,
                pinnedGlyph: row.glyphImage?.size.width ?? 0,
                listRowHeight: listRow.bounds.height, listTitle: listRow.title.font.pointSize, listGlyph: listGlyph,
                cardPadding: card.kindIconFrame.minX, cardIcon: card.kindIconFrame.width,
                cardTitle: card.drawnTitleFont?.pointSize ?? 0, cardCaption: card.drawnCaptionFont?.pointSize ?? 0,
                cardWidth: widest, cardMinWidth: narrowest, tabRowHeight: tab.frame.height, tabHasDetail: tab.hasDetail,
                detailTabRowHeight: chatRow.frame.height, detailTabHasDetail: chatRow.hasDetail, tabTitle: tab.titleFont?.pointSize ?? 0,
                tabIcon: tab.iconFrame.width, disclosureHeight: card.detailsToggle.fittingSize.height)
            print("PINNEDSIZE|\(setting)|row \(measured.pinnedRowHeight) vs \(measured.listRowHeight)|title \(measured.pinnedTitle) vs \(measured.listTitle)"
                + "|glyph \(measured.pinnedGlyph) vs \(measured.listGlyph)|card pad \(measured.cardPadding) icon \(measured.cardIcon)"
                + " title \(measured.cardTitle) caption \(measured.cardCaption) width \(measured.cardMinWidth)...\(measured.cardWidth)"
                + "|tab \(measured.tabRowHeight) title \(measured.tabTitle) icon \(measured.tabIcon)|disclosure \(measured.disclosureHeight)")
            return measured
        }
    }

    /// The pinned row matches a workspace row at the same setting: height, title font and icon side.
    @Test(arguments: settings)
    func aPinnedRowMatchesAWorkspaceRow(_ setting: Setting) throws {
        let m = try Self.measure(setting)
        let tokens = Self.at(setting) { SidebarRowTokens.current }
        #expect(m.pinnedRowHeight == tokens.rowHeight, "\(setting): pinned row \(m.pinnedRowHeight), token \(tokens.rowHeight)")
        #expect(m.pinnedRowHeight == m.listRowHeight, "\(setting): pinned row \(m.pinnedRowHeight), workspace row \(m.listRowHeight)")
        #expect(m.pinnedTitle == tokens.titleSize, "\(setting): pinned title \(m.pinnedTitle), token \(tokens.titleSize)")
        #expect(m.pinnedTitle == m.listTitle, "\(setting): pinned title \(m.pinnedTitle), workspace title \(m.listTitle)")
        // A workspace favicon's bitmap is drawn 4/3 its optical side so the ink, not the bitmap's transparent margin, fills
        // `SidebarStyle.rowGlyphOpticalSide` (Lawrence 2026-11-09, one icon size); compare the sizes it draws at.
        let listOptical = m.listGlyph * 3 / 4
        #expect(abs(m.pinnedGlyph - listOptical) <= 0.5, "\(setting): pinned icon \(m.pinnedGlyph), workspace icon \(listOptical)")
    }

    /// The card the pinned row opens takes its sizes from ``SidebarRowTokens/hoverCard``.
    @Test(arguments: settings)
    func theCardEqualsItsTokens(_ setting: Setting) throws {
        let m = try Self.measure(setting)
        let card = Self.at(setting) { SidebarRowTokens.current.hoverCard }
        #expect(m.cardPadding == card.padding, "\(setting): padding \(m.cardPadding), token \(card.padding)")
        #expect(m.cardIcon == card.iconSide, "\(setting): icon \(m.cardIcon), token \(card.iconSide)")
        #expect(m.cardTitle == card.titleSize, "\(setting): title \(m.cardTitle), token \(card.titleSize)")
        #expect(m.cardCaption == card.captionSize, "\(setting): caption \(m.cardCaption), token \(card.captionSize)")
        #expect(m.cardWidth == card.maxWidth, "\(setting): widest \(m.cardWidth), token \(card.maxWidth)")
        #expect(m.cardMinWidth == card.minWidth, "\(setting): narrowest \(m.cardMinWidth), token \(card.minWidth)")
        // A tab with no detail line is one row tall (#37176, Leo 2026-11-06: "you got all these empty things"); the
        // fixture's shell tab has no command, place or state, so it takes the one-line token.
        #expect(!m.tabHasDetail, "\(setting): the shell tab drew a detail line")
        #expect(m.tabRowHeight == card.tabRowHeight, "\(setting): tab row \(m.tabRowHeight), token \(card.tabRowHeight)")
        // A tab with a detail line is two rows tall at every density and text size.
        #expect(m.detailTabHasDetail, "\(setting): the chat tab drew no detail line")
        #expect(m.detailTabRowHeight == card.tabRowHeightTwoLines,
                "\(setting): two-line tab row \(m.detailTabRowHeight), token \(card.tabRowHeightTwoLines)")
        #expect(m.tabTitle == card.titleSize, "\(setting): tab title \(m.tabTitle), token \(card.titleSize)")
        #expect(m.tabIcon == card.iconSide, "\(setting): tab icon \(m.tabIcon), token \(card.iconSide)")
        #expect(m.disclosureHeight == card.disclosureHeight, "\(setting): disclosure \(m.disclosureHeight), token \(card.disclosureHeight)")
    }

    /// Every size grows with the text size, and none shrinks from compact to comfortable.
    @Test(arguments: [SidebarDensity.compact, .comfortable, .expanded])
    func sizesGrowWithTheTextSize(_ density: SidebarDensity) throws {
        let sizes = try SidebarTextSize.allCases.map { try Self.measure(Setting(density: density, textSize: $0)) }
        for (smaller, bigger) in zip(sizes, sizes.dropFirst()) {
            #expect(bigger.pinnedRowHeight > smaller.pinnedRowHeight)
            #expect(bigger.pinnedTitle > smaller.pinnedTitle)
            // The workspace row's own icon holds at comfortable from large to larger (it fills the 20 pt column);
            // the pinned row matches it, so its icon never shrinks rather than always grows.
            #expect(bigger.pinnedGlyph >= smaller.pinnedGlyph, "\(density): pinned icon \(smaller.pinnedGlyph) → \(bigger.pinnedGlyph)")
            #expect(bigger.cardIcon > smaller.cardIcon, "\(density): card icon \(smaller.cardIcon) → \(bigger.cardIcon)")
            #expect(bigger.cardTitle > smaller.cardTitle, "\(density): card title \(smaller.cardTitle) → \(bigger.cardTitle)")
            #expect(bigger.cardCaption > smaller.cardCaption)
            #expect(bigger.cardWidth > smaller.cardWidth, "\(density): card width \(smaller.cardWidth) → \(bigger.cardWidth)")
            #expect(bigger.tabRowHeight > smaller.tabRowHeight, "\(density): tab row \(smaller.tabRowHeight) → \(bigger.tabRowHeight)")
            #expect(bigger.disclosureHeight > smaller.disclosureHeight)
        }
    }

    @Test(arguments: SidebarTextSize.allCases)
    func comfortableIsNeverSmallerThanCompact(_ textSize: SidebarTextSize) throws {
        let compact = try Self.measure(Setting(density: .compact, textSize: textSize))
        let comfortable = try Self.measure(Setting(density: .comfortable, textSize: textSize))
        #expect(comfortable.pinnedRowHeight > compact.pinnedRowHeight)
        #expect(comfortable.pinnedGlyph > compact.pinnedGlyph, "\(textSize): pinned icon \(compact.pinnedGlyph) → \(comfortable.pinnedGlyph)")
        #expect(comfortable.cardPadding > compact.cardPadding, "\(textSize): card padding \(compact.cardPadding) → \(comfortable.cardPadding)")
        #expect(comfortable.tabRowHeight > compact.tabRowHeight, "\(textSize): tab row \(compact.tabRowHeight) → \(comfortable.tabRowHeight)")
        #expect(comfortable.disclosureHeight > compact.disclosureHeight)
        #expect(comfortable.cardWidth >= compact.cardWidth)
    }
}
