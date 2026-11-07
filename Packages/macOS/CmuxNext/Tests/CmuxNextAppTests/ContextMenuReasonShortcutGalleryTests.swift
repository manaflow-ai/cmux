import AppKit
import Foundation
import Testing

/// The tab menu's close rows as Leo saw them (2026-11-07: ⌥⌘T drawn over "Pinned tabs stay open."),
/// then three ways to keep a row's reason clear of the shortcut column, light and dark, each labelled
/// with whether any reason line crosses a shortcut. An open NSMenu cannot be drawn offscreen, so the
/// rows are laid out as AppKit lays them: icon column, title, the subtitle under it at the small menu
/// font, and one right-aligned shortcut column for the whole menu. Artifact
/// `context-menu-reason-shortcut-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct ContextMenuReasonShortcutGalleryTests {
    enum Variant: String, CaseIterable {
        /// Base: the subtitle runs under the shortcut column and the shortcut draws on it.
        case today
        /// Chosen: a row that shows a reason shows no shortcut (`ActionTargetTitles.hideShortcut`).
        case hideShortcut
        /// The reason wraps at the widest title, so it ends before the shortcut column.
        case wrapBeforeShortcut
        /// The reason is cut with an ellipsis before the shortcut column; the full text is the tooltip.
        case truncateBeforeShortcut
    }

    struct Row {
        var symbol: String
        var title: String
        var shortcut = ""
        var reason: String?
    }

    static let rows: [Row?] = [
        Row(symbol: "plus.square", title: "New Tab to the Right"),
        Row(symbol: "plus.square.on.square", title: "Duplicate Tab"),
        nil,
        Row(symbol: "pin", title: "Pin Tab", shortcut: "⌥⌘P"),
        Row(symbol: "xmark", title: "Close Tab", shortcut: "⌘W"),
        Row(symbol: "xmark.circle", title: "Close Other Tabs", shortcut: "⌥⌘T",
            reason: "There are no other tabs to close. Pinned tabs stay open."),
        Row(symbol: "arrow.right.to.line.compact", title: "Close Tabs to the Right",
            reason: "There are no tabs to the right to close."),
        nil,
        Row(symbol: "slider.horizontal.3", title: "Customize Menu…"),
    ]

    static let titleFont = NSFont.menuFont(ofSize: 0)
    static let reasonFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
    static let inset: CGFloat = 14, iconColumn: CGFloat = 24, shortcutGap: CGFloat = 24
    static let rowHeight: CGFloat = 22, reasonLine: CGFloat = 15, separatorHeight: CGFloat = 11

    static func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }

    /// The lines of `reason` no wider than `limit` at the reason font, breaking between words.
    static func wrap(_ reason: String, to limit: CGFloat) -> [String] {
        var lines: [String] = [], line = ""
        for word in reason.split(separator: " ") {
            let next = line.isEmpty ? String(word) : line + " " + word
            if width(next, reasonFont) <= limit || line.isEmpty { line = next } else { lines.append(line); line = String(word) }
        }
        return line.isEmpty ? lines : lines + [line]
    }

    static func truncate(_ reason: String, to limit: CGFloat) -> String {
        guard width(reason, reasonFont) > limit else { return reason }
        var text = reason
        while !text.isEmpty, width(text + "…", reasonFont) > limit { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One laid-out row: its reason lines and whether it draws its shortcut.
    struct Laid {
        var row: Row
        var lines: [String]
        var drawsShortcut: Bool
    }

    struct MenuLayout {
        var rows: [Laid?]
        var width: CGFloat
        var shortcutColumnX: CGFloat
        /// Rows whose drawn reason crosses the drawn shortcut's column.
        var overlaps: [String]
        var height: CGFloat
    }

    static func menuLayout(_ variant: Variant) -> MenuLayout {
        let present = rows.compactMap { $0 }
        let maxTitle = present.map { Self.width($0.title, titleFont) }.max() ?? 0
        let maxShortcut = present.map { Self.width($0.shortcut, titleFont) }.max() ?? 0
        let textX = inset + iconColumn
        let shortcutColumnX = textX + maxTitle + shortcutGap
        let laid: [Laid?] = rows.map { row in
            guard let row else { return nil }
            guard let reason = row.reason else { return Laid(row: row, lines: [], drawsShortcut: true) }
            switch variant {
            case .today: return Laid(row: row, lines: [reason], drawsShortcut: true)
            case .hideShortcut: return Laid(row: row, lines: [reason], drawsShortcut: false)
            case .wrapBeforeShortcut: return Laid(row: row, lines: wrap(reason, to: maxTitle), drawsShortcut: true)
            case .truncateBeforeShortcut: return Laid(row: row, lines: [truncate(reason, to: maxTitle)], drawsShortcut: true)
            }
        }
        // AppKit sizes the menu to its widest title plus shortcut column, and to its widest subtitle.
        let widestReason = laid.compactMap { $0 }.flatMap(\.lines).map { Self.width($0, reasonFont) }.max() ?? 0
        let menuWidth = max(shortcutColumnX + maxShortcut, textX + widestReason) + inset
        let overlaps = laid.compactMap { $0 }.filter { laid in
            guard laid.drawsShortcut, !laid.row.shortcut.isEmpty else { return false }
            let shortcutX = menuWidth - inset - Self.width(laid.row.shortcut, titleFont)
            return laid.lines.contains { textX + Self.width($0, reasonFont) > shortcutX }
        }.map(\.row.title)
        let height = laid.reduce(CGFloat(10)) { total, row in
            total + (row.map { rowHeight + CGFloat($0.lines.count) * reasonLine } ?? separatorHeight)
        }
        return MenuLayout(rows: laid, width: menuWidth, shortcutColumnX: shortcutColumnX, overlaps: overlaps, height: height)
    }

    /// Fixed inks for the offscreen render: the dynamic secondary and tertiary label colors drew
    /// nothing through `cacheDisplay` (the first gallery lost every disabled row, shortcut and caption).
    struct Inks {
        var primary, disabled, shortcut, caption, separator, fill, backdrop: NSColor
        init(dark: Bool) {
            let ink = NSColor(white: dark ? 1 : 0, alpha: 1)
            primary = ink.withAlphaComponent(0.88)
            disabled = ink.withAlphaComponent(0.32)
            shortcut = ink.withAlphaComponent(0.45)
            caption = ink.withAlphaComponent(0.6)
            separator = ink.withAlphaComponent(0.14)
            fill = dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            backdrop = dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.9, alpha: 1)
        }
    }

    /// Draws a layout as a menu.
    final class MenuView: NSView {
        let layout: MenuLayout
        let inks: Inks
        init(_ layout: MenuLayout, inks: Inks) {
            self.layout = layout
            self.inks = inks
            super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let textX = ContextMenuReasonShortcutGalleryTests.inset + ContextMenuReasonShortcutGalleryTests.iconColumn
            let title = ContextMenuReasonShortcutGalleryTests.titleFont, small = ContextMenuReasonShortcutGalleryTests.reasonFont
            var y: CGFloat = 5
            for laid in layout.rows {
                guard let laid else {
                    inks.separator.setFill()
                    NSRect(x: 10, y: y + 5, width: layout.width - 20, height: 1).fill()
                    y += ContextMenuReasonShortcutGalleryTests.separatorHeight
                    continue
                }
                let enabled = laid.row.reason == nil
                let ink = enabled ? inks.primary : inks.disabled
                if let image = NSImage(systemSymbolName: laid.row.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: title.pointSize, weight: .regular).applying(.init(hierarchicalColor: ink))) {
                    image.draw(in: NSRect(x: ContextMenuReasonShortcutGalleryTests.inset, y: y + 3, width: 16, height: 16))
                }
                (laid.row.title as NSString).draw(at: NSPoint(x: textX, y: y + 2), withAttributes: [.font: title, .foregroundColor: ink])
                if laid.drawsShortcut, !laid.row.shortcut.isEmpty {
                    let x = layout.width - ContextMenuReasonShortcutGalleryTests.inset
                        - ContextMenuReasonShortcutGalleryTests.width(laid.row.shortcut, title)
                    let shortcutY = y + 2 + (laid.lines.isEmpty ? 0 : ContextMenuReasonShortcutGalleryTests.reasonLine * 0.5)
                    (laid.row.shortcut as NSString).draw(at: NSPoint(x: x, y: shortcutY),
                                                         withAttributes: [.font: title, .foregroundColor: inks.shortcut])
                }
                var lineY = y + ContextMenuReasonShortcutGalleryTests.rowHeight - 3
                for line in laid.lines {
                    (line as NSString).draw(at: NSPoint(x: textX, y: lineY), withAttributes: [.font: small, .foregroundColor: ink])
                    lineY += ContextMenuReasonShortcutGalleryTests.reasonLine
                }
                y += ContextMenuReasonShortcutGalleryTests.rowHeight + CGFloat(laid.lines.count) * ContextMenuReasonShortcutGalleryTests.reasonLine
            }
        }
    }

    static func panel(_ variant: Variant, appearance: NSAppearance) -> NSView {
        let shown = menuLayout(variant)
        let inks = Inks(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let box = NSView(frame: NSRect(origin: .zero, size: CGSize(width: shown.width, height: shown.height)))
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = inks.fill.cgColor
        box.addSubview(MenuView(shown, inks: inks))
        box.widthAnchor.constraint(equalToConstant: shown.width).isActive = true
        box.heightAnchor.constraint(equalToConstant: shown.height).isActive = true
        let caption = NSTextField(wrappingLabelWithString: label(variant))
        caption.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = inks.caption
        caption.preferredMaxLayoutWidth = max(shown.width, 320)
        let outer = NSStackView(views: [box, caption])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        outer.appearance = appearance
        outer.wantsLayer = true
        outer.layer?.backgroundColor = inks.backdrop.cgColor
        outer.frame = NSRect(origin: .zero, size: outer.fittingSize)
        outer.layoutSubtreeIfNeeded()
        return outer
    }

    static func label(_ variant: Variant) -> String {
        let shown = menuLayout(variant), today = menuLayout(.today)
        let overlap = shown.overlaps.isEmpty ? "no reason crosses a shortcut" : "reason crosses the shortcut on \(shown.overlaps.joined(separator: ", "))"
        return "\(variant.rawValue): \(overlap); \(Int(shown.width)) × \(Int(shown.height)) pt (today \(Int(today.width)) × \(Int(today.height)))"
    }

    /// The gallery's own measure: today draws ⌥⌘T over its reason; every fix draws none over any reason.
    @Test func onlyTodayDrawsAShortcutOverAReason() {
        #expect(Self.menuLayout(.today).overlaps == ["Close Other Tabs"])
        for variant in Variant.allCases where variant != .today {
            #expect(Self.menuLayout(variant).overlaps.isEmpty, "\(variant)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryVariant() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "context-menu-reason-shortcut-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [String] = []
        for (index, variant) in Variant.allCases.enumerated() {
            lines.append("\(index)-\(variant.rawValue): \(Self.label(variant))")
            for (look, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let image = try TitlebarHistoryMenuGalleryTests.render(Self.panel(variant, appearance: try #require(NSAppearance(named: name))))
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(index)-\(variant.rawValue)-\(look).png"))
            }
        }
        print("context-menu-reason-shortcut: " + lines.joined(separator: " | "))
        try lines.joined(separator: "\n").write(to: out.appending(path: "measurements.txt"), atomically: true, encoding: .utf8)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "context-menu-reason-shortcut-gallery.tar", "context-menu-reason-shortcut-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
