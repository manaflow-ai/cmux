import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Leo, 2026-10-21, on the chat's right-click menu (Copy, Quote in Reply, Ask About This, Search
/// the Web): "so much ... padding ... all over the place". A themed menu's rows keep
/// native macOS menu metrics: 22pt rows in the native menu font, icons that fit a 14pt box with
/// their shape kept, content at AppKit's own leading (no empty state column), the highlight 5pt
/// in from the edge. The glass panel, its corners and its separators stay AppKit's.
@MainActor @Suite struct ThemedMenuMetricsTests {
    /// The chat's selection menu, themed as the agent pane themes it.
    private static func selectionMenu(checked: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let rows = [("Copy", "doc.on.doc"), ("Quote in Reply", "text.quote"), ("Ask About This", "questionmark.bubble"),
                    ("-", ""), ("Search the Web", "magnifyingglass")]
        for (title, symbol) in rows {
            if title == "-" {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(NSText.copy(_:)), keyEquivalent: "")
            item.image = .menuSymbol(symbol)
            menu.addItem(item)
        }
        if checked { menu.items[0].state = .on }
        menu.themeRows(in: ThemeScope(level: .room))
        return menu
    }

    @Test func rowsAreNativeMenuRows() throws {
        let menu = Self.selectionMenu()
        for item in menu.items where !item.isSeparatorItem {
            let row = try #require(item.view as? ThemedMenuRowView, "\(item.title) is a themed row")
            #expect(row.frame.height == 22, "\(item.title) is \(row.frame.height)pt tall, not a native 22pt row")
            let font = ThemedMenuRowView.font(of: item)
            #expect(font.pointSize == NSFont.menuFont(ofSize: 0).pointSize, "\(item.title) draws in the native menu font")
            #expect(font.pointSize <= 14)
        }
        #expect(ThemedMenuRowView.rowHeight == 22)
        #expect(ThemedMenuRowView.inset == 5, "the highlight sits 5pt in from the menu's edge")
        #expect(ThemedMenuRowView.radius <= 6, "the highlight is a small rounded rect, not a pill")
    }

    private static func row(_ item: NSMenuItem) throws -> ThemedMenuRowView {
        try #require(item.view as? ThemedMenuRowView, "\(item.title) is a themed row")
    }

    /// Where `item`'s icon, or its title without one, starts in its themed row.
    private static func leading(_ item: NSMenuItem) throws -> CGFloat {
        let columns = try row(item).columns
        return ThemedMenuRowView.leading(of: item, in: columns)
    }

    /// No row has a checkmark, so no row leaves room for one: the icon starts at AppKit's leading,
    /// where the native separators start.
    @Test func noEmptyStateColumn() throws {
        let menu = Self.selectionMenu()
        let copy = menu.items[0]
        #expect(try !Self.row(copy).columns.state)
        #expect(try Self.leading(copy) == 15)
        let titleWidth = NSAttributedString(string: copy.title, attributes: [.font: ThemedMenuRowView.font(of: copy)]).size().width
        #expect(try Self.row(copy).frame.width == ceil(15 + 14 + 6 + titleWidth + 12), "leading 15, icon 14, gap 6, title, trailing 12")

        // A menu with a checkmark keeps the state column, as a native menu does.
        let checked = Self.selectionMenu(checked: true)
        #expect(try Self.row(checked.items[4]).columns.state)
        #expect(try Self.leading(checked.items[4]) == ThemedMenuRowView.stateTitleX)

        // A hidden checked row (the device menu's search hides its browse rows) leaves no column
        // in the rows that show, measured and drawn alike.
        let searching = Self.selectionMenu(checked: true)
        searching.items[0].isHidden = true
        let result = NSMenuItem(title: "Search the Web", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        result.image = .menuSymbol("magnifyingglass")
        searching.addItem(result)
        searching.themeAddedRows()
        #expect(try !Self.row(result).columns.state)
        #expect(try Self.leading(result) == 15)
        #expect(try Self.leading(searching.items[4]) == 15, "a row themed before the search drops the column too")
        let withColumn = try Self.row(checked.items[4]).frame.width
        #expect(try Self.row(result).frame.width == withColumn - (ThemedMenuRowView.stateTitleX - 15))
    }

    /// A row's draw reads the columns measured when its menu was themed, never the menu's other
    /// rows (Codex on #24036: a scan per row draw is O(rows²) per redraw of a long device menu).
    /// A checked row added to the open menu and themed into it moves every row into the state column.
    @Test func columnsAreMeasuredOncePerTheming() throws {
        let menu = NSMenu()
        for index in 0..<200 {
            let item = NSMenuItem(title: "Device \(index)", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            item.image = .menuSymbol("iphone")
            menu.addItem(item)
        }
        let beforeTheming = ThemedMenuColumns.measurements
        menu.themeRows(in: ThemeScope(level: .room))
        #expect(ThemedMenuColumns.measurements == beforeTheming + 1, "theming measures the menu once, not once per row")
        let rows = try menu.items.map { try Self.row($0) }
        #expect(rows.allSatisfy { $0.columns == ThemedMenuColumns(state: false, icon: true) })

        let beforeDrawing = ThemedMenuColumns.measurements
        for row in rows.prefix(20) {
            row.frame.size.width = 240
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
        }
        #expect(ThemedMenuColumns.measurements == beforeDrawing, "a row's draw measures no menu")

        let checked = NSMenuItem(title: "iPhone 17", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        checked.state = .on
        menu.addItem(checked)
        menu.themeAddedRows()
        #expect(ThemedMenuColumns.measurements == beforeDrawing + 1)
        let checkedRow = try Self.row(checked)
        for row in rows + [checkedRow] {
            #expect(row.columns == ThemedMenuColumns(state: true, icon: true))
        }
        #expect(try Self.leading(menu.items[0]) == ThemedMenuRowView.stateTitleX)
        #expect(try Self.leading(checked) == ThemedMenuRowView.stateTitleX)
    }

    /// An icon fits the 14pt box with its shape kept, scaled down and never up: an SF Symbol is
    /// rarely square, and stretching it to a square made the menu's icons look oversized.
    @Test func iconsFitAFourteenPointBox() throws {
        #expect(ThemedMenuRowView.imageSide == 14)
        let box = NSRect(x: 15, y: 4, width: 14, height: 14)
        #expect(ThemedMenuRowView.fitted(NSSize(width: 20, height: 10), in: box) == NSRect(x: 15, y: 7.5, width: 14, height: 7))
        let tall = ThemedMenuRowView.fitted(NSSize(width: 12, height: 16), in: box)
        #expect(tall.height == 14 && abs(tall.width - 10.5) < 0.001 && abs(tall.midX - 22) < 0.001 && tall.midY == 11)
        #expect(ThemedMenuRowView.fitted(NSSize(width: 10, height: 10), in: box) == NSRect(x: 17, y: 6, width: 10, height: 10))
        for symbol in ["doc.on.doc", "text.quote", "questionmark.bubble", "magnifyingglass"] {
            let size = try #require(NSImage.menuSymbol(symbol), "\(symbol) is a system symbol").size
            let rect = ThemedMenuRowView.fitted(size, in: NSRect(x: 0, y: 0, width: 14, height: 14))
            #expect(rect.width <= 14.001 && rect.height <= 14.001, "\(symbol) draws \(rect.size)")
            #expect(abs(rect.width / rect.height - size.width / size.height) < 0.01, "\(symbol) keeps its shape")
        }
    }

    /// The separators, the glass panel and its corners are AppKit's own, the same as every native menu's.
    @Test func separatorsStayNative() {
        let menu = Self.selectionMenu()
        let separator = menu.items[3]
        #expect(separator.isSeparatorItem)
        #expect(separator.view == nil, "a themed menu keeps AppKit's thin separator")
    }
}
