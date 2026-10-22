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

    /// No row has a checkmark, so no row leaves room for one: the icon starts at AppKit's leading,
    /// where the native separators start.
    @Test func noEmptyStateColumn() throws {
        let menu = Self.selectionMenu()
        let copy = menu.items[0]
        #expect(!ThemedMenuRowView.hasStateColumn(copy))
        #expect(ThemedMenuRowView.leading(of: copy) == 15)
        let titleWidth = NSAttributedString(string: copy.title, attributes: [.font: ThemedMenuRowView.font(of: copy)]).size().width
        let row = try #require(copy.view)
        #expect(row.frame.width == ceil(15 + 14 + 6 + titleWidth + 12), "leading 15, icon 14, gap 6, title, trailing 12")

        // A menu with a checkmark keeps the state column, as a native menu does.
        let checked = Self.selectionMenu(checked: true)
        #expect(ThemedMenuRowView.hasStateColumn(checked.items[4]))
        #expect(ThemedMenuRowView.leading(of: checked.items[4]) == ThemedMenuRowView.stateTitleX)
    }

    /// An icon fits the 14pt box with its shape kept: an SF Symbol is rarely square, and stretching
    /// it to a square made the menu's icons look oversized.
    @Test func iconsFitAFourteenPointBox() {
        #expect(ThemedMenuRowView.imageSide == 14)
        let wide = ThemedMenuRowView.iconRect(for: NSSize(width: 20, height: 10), x: 15, midY: 11)
        #expect(wide == NSRect(x: 15, y: 7.5, width: 14, height: 7))
        let tall = ThemedMenuRowView.iconRect(for: NSSize(width: 12, height: 16), x: 15, midY: 11)
        #expect(tall.height == 14 && abs(tall.width - 10.5) < 0.001 && abs(tall.midX - 22) < 0.001 && tall.midY == 11)
        for symbol in ["doc.on.doc", "text.quote", "questionmark.bubble", "magnifyingglass"] {
            guard let size = NSImage.menuSymbol(symbol)?.size else { continue }
            let rect = ThemedMenuRowView.iconRect(for: size, x: 0, midY: 0)
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
