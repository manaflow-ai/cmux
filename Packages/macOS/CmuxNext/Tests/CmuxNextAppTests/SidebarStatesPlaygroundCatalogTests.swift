import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Sidebar States Playground (Lawrence msg 19746: "show me all the possible sidebar states") covers every state
/// he listed, and each one is a real row the sidebar drew with the mark that state draws: the catalog renders the
/// fixture through the playground's own renderer and reads what each real row laid out.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatesPlaygroundCatalogTests {
    /// Every state the request named, in his words, and the playground state that shows it.
    static let requested: [(String, SidebarStatesPlaygroundState)] = [
        ("idle", .idle), ("busy spinner", .busy), ("unread blue dot", .unread), ("orange", .needsYou),
        ("red warning", .error), ("needs-input", .needsInput), ("pinned", .pinned), ("selected", .selected),
        ("hovered", .hovered), ("renaming", .renaming), ("archived", .archived), ("remote/ssh", .remote),
        ("group header expanded", .groupExpanded), ("group header collapsed with roll-ups", .groupCollapsed),
        ("Home row", .home), ("empty group +", .emptyGroup),
        ("left selection/accent bar", .accentBar), ("group rail", .groupRail), // Lawrence msg 19775
        ("GitHub mono favicon", .faviconMono), ("colourful favicon", .faviconColorful), ("no-favicon globe placeholder", .faviconMissing),
        ("pinned summary at each density", .pinnedHoverCard), // Lawrence 2026-11-03, the pinned row's hover card
    ]

    /// The row view class each state must be drawn by.
    static func rowView(_ state: SidebarStatesPlaygroundState) -> String {
        switch state {
        case .pinned, .pinnedHoverCard, .home: "SidebarItemRowView"
        case .groupExpanded, .groupCollapsed, .emptyGroup: "GroupHeaderRowView"
        default: "WorkspaceRowView"
        }
    }

    nonisolated static let columns = [SidebarStatesPlaygroundColumn(density: .compact, textSize: .standard),
                          SidebarStatesPlaygroundColumn(density: .expanded, textSize: .larger)]

    @Test func everyRequestedStateIsAPlaygroundRow() {
        let shown = Set(SidebarStatesPlaygroundState.allCases)
        for (words, state) in Self.requested { #expect(shown.contains(state), "\(words) has no playground row") }
        #expect(Set(Self.requested.map(\.1)).count == Self.requested.count, "two requested states share one row")
        #expect(SidebarStatesPlaygroundColumn.all.count == SidebarDensity.allCases.count * SidebarTextSize.allCases.count)
    }

    @Test(arguments: columns)
    func everyStateIsItsRealRowWithItsMark(_ column: SidebarStatesPlaygroundColumn) throws {
        let renderer = SidebarStatesPlaygroundRenderer(design: .shared, themes: SidebarStatesPlaygroundThemes(colors: [:]))
        let before = DesignSettings.shared.sidebarSections
        let cells = renderer.cells(column, .dark)
        let after = DesignSettings.shared.sidebarSections
        #expect(after.density == before.density && after.textSize == before.textSize, "the renderer put the user's settings back")
        for state in SidebarStatesPlaygroundState.allCases {
            let cell = try #require(cells[state], "\(state): no cell")
            #expect(cell.image != nil, "\(state) at \(column.density)/\(column.textSize): the sidebar drew no row")
            #expect(cell.rowView == Self.rowView(state), "\(state): drawn by \(cell.rowView ?? "nothing")")
            #expect(cell.leadingGuideX != nil && cell.columnGuideX != nil, "\(state): a guide was not measured")
            let marks = cell.marks
            func has(_ view: String, _ state: String? = nil) -> Bool {
                marks.contains { $0.view == view && (state == nil || $0.state == state) }
            }
            switch state {
            case .idle, .accentBar: #expect(marks.isEmpty, "an idle row draws no trailing mark: \(marks)")
            case .busy: #expect(has("StatusIndicatorView", "working"), "\(marks)")
            case .unread: #expect(has("StatusIndicatorView", "success") || has("UnreadBadgeView"), "\(marks)")
            case .needsYou, .needsInput: #expect(has("StatusIndicatorView", "waiting"), "\(state): \(marks)")
            case .error: #expect(has("StatusIndicatorView", "error"), "\(marks)")
            case .usageWarning: #expect(has("DecorativeImageView"), "\(marks)")
            case .hovered: #expect(marks.contains { $0.view.hasSuffix("Button") }, "a hovered row shows its controls: \(marks)")
            case .groupExpanded: #expect(has("DisclosureChevronView"), "\(marks)")
            case .groupCollapsed: #expect(marks.contains { $0.view == "StatusIndicatorView" && $0.state != nil }, "no roll-up: \(marks)")
            case .home: #expect(!marks.isEmpty, "Home's unread dot: \(marks)")
            case .emptyGroup: #expect(has("SidebarIconButton"), "the empty group's +: \(marks)")
            case .pinned, .renaming, .archived, .remote, .selected, .accentBar, .groupRail, .faviconMono, .faviconColorful,
                 .faviconMissing, .pinnedHoverCard: break
            }
            // Lawrence msg 19775: the colored selected, hovered and resting rows show their leading accent bar.
            if [.selected, .hovered, .accentBar].contains(state) {
                #expect(cell.bars.contains { $0.view != "GroupLineView" && $0.frame.height > 0 }, "\(state): no accent bar: \(cell.bars)")
            }
            for mark in marks {
                #expect(mark.frame.width > 0 && mark.frame.height > 0, "\(state): \(mark.view) laid out empty")
            }
        }
        // The pinned row's hover card: the real card drawn beside its row (to the sidebar's right, its top on the
        // row's), with tab rows, at this density's sizes.
        let pinned = try #require(cells[.pinnedHoverCard])
        let card = try #require(pinned.card, "the pinned row's hover card was not drawn")
        #expect(card.frame.minX >= pinned.rowFrame.maxX - 0.5, "the card sits beside its row: \(card.frame) vs \(pinned.rowFrame)")
        #expect(abs(card.frame.minY - pinned.rowFrame.minY) < 1, "the card's top is on its row's top")
        #expect(card.frame.width > 100 && card.frame.height > 40, "card \(card.frame.size)")
        #expect(!card.tabRowHeights.isEmpty && card.tabRowHeights.allSatisfy { $0 > 0 }, "tab rows \(card.tabRowHeights)")
        #expect(pinned.size.width >= card.frame.maxX, "the cell holds the card")
        // The favicon slot: each favicon row's leading icon draws its own favicon (or the fallback), so the three
        // rows' pixels left of the title differ.
        let leading = try [SidebarStatesPlaygroundState.faviconMono, .faviconColorful, .faviconMissing].map { state in
            let cell = try #require(cells[state])
            return try Self.leadingPixels(cell)
        }
        #expect(leading[0] != leading[1] && leading[1] != leading[2] && leading[0] != leading[2], "two favicon rows draw the same icon")
    }

    /// The favicon styles sheets (Lawrence msg 19869): one sheet per `sidebar.faviconStyle`, each at every density and
    /// text size and drawn with its style.
    /// On the dark sheet the dark mono favicon reads differently as fetched and with the default adaptive tint, and the
    /// renderer puts the person's own style back after each column.
    @Test func everyFaviconStyleIsAColumnDrawnWithItsStyle() throws {
        for style in SidebarFaviconStyle.allCases {
            let columns = SidebarStatesPlaygroundColumn.favicons(style)
            #expect(columns.allSatisfy { $0.faviconStyle == style }, "\(style): a column draws another style")
            #expect(Set(columns.map { [$0.density.rawValue, $0.textSize.rawValue] }).count
                        == SidebarDensity.allCases.count * SidebarTextSize.allCases.count, "\(style): a density and text size is missing")
        }
        #expect(Set(SidebarFaviconStyle.allCases.map(SidebarStatesPlaygroundColumn.title)).count == SidebarFaviconStyle.allCases.count,
                "two favicon style sheets share a title")
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarFaviconStyle.tunable.key
        let mine = SidebarFaviconStyle.monochrome.tunableValue
        TunableStore.shared.set(key, mine)
        defer { TunableStore.shared.set(key, nil) }
        let renderer = SidebarStatesPlaygroundRenderer(design: .shared, themes: SidebarStatesPlaygroundThemes(colors: [:]))
        var leading: [SidebarFaviconStyle: [UInt8]] = [:]
        for column in [SidebarFaviconStyle.current, .adaptive].compactMap({ SidebarStatesPlaygroundColumn.favicons($0).first }) {
            let cells = renderer.cells(column, .dark)
            #expect(TunableStore.shared.override(key) == mine, "the renderer did not put the person's favicon style back")
            let cell = try #require(cells[.faviconMono], "\(column.title): no favicon row")
            leading[try #require(column.faviconStyle)] = try Self.leadingPixels(cell)
        }
        #expect(leading[.current] != leading[.adaptive], "the adaptive column draws the dark mono favicon as fetched")
    }

    /// The RGBA bytes of `cell`'s row left of where a title after an icon starts: the leading inset guide plus the icon
    /// column. A leading icon's ink starts on the guide (Lawrence 2026-11-09, one left edge), so its pixels are right of it.
    static func leadingPixels(_ cell: SidebarStatesPlaygroundCell) throws -> [UInt8] {
        let image = try #require(cell.image), guide = try #require(cell.leadingGuideX)
        let width = min(image.width, Int(((guide + SidebarStyle.rowGlyphOpticalSide) * cell.scale).rounded())), height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return bytes
    }
}
