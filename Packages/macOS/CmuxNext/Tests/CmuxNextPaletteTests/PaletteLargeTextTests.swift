import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// #26606: at a large text size the Search placeholder ("Search workspaces, tabs, history, chats,
/// settings and commands…") is wider than the field. It had no line break mode, so it wrapped inside
/// the one-line field and showed the bottom of one line and the top of the next: clipped top and
/// bottom. At every density, with the largest Interface Size (16 pt) and the largest density text
/// size (20 pt), the placeholder must truncate on one line, and every label (search field, rows,
/// headers, footer) must sit inside its row at its style's size.
///
/// Also draws every case into one PNG (`CMUX_PALETTE_LARGE_TEXT_SNAPSHOT_PATH`, else
/// `.build/palette-large-text.png` in the package) for the PR: Search on the left, the command
/// list on the right.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteLargeTextTests {
    private struct Case {
        let tokens: DensityTokens
        let label: String
    }

    private static var cases: [Case] {
        DensityPreset.allCases.flatMap { preset -> [Case] in
            [16.0, 20.0].map { size in
                var tokens = preset.tokens
                tokens.fontSize = size
                return Case(tokens: tokens, label: "\(preset.tokens.name), \(Int(size)) pt")
            }
        }
    }

    @Test func textFitsItsRowsAtEveryDensity() async throws {
        _ = NSApplication.shared
        let search = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        #expect(search.show(scope: PaletteScopeID.search))
        await search.model.settle()
        let commands = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        commands.show(.commands)
        await commands.model.settle()
        defer {
            search.closeForTest()
            commands.closeForTest()
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        var images: [(String, NSImage)] = []
        for item in Self.cases {
            try DensityTokens.$scoped.withValue(item.tokens) {
                images.append(("Search, \(item.label)", try Self.check(search.model, item.label, windows: &windows, rows: 0)))
                images.append(("Commands, \(item.label)", try Self.check(commands.model, item.label, windows: &windows, rows: 5)))
            }
        }
        try Self.writeSheet(images)
    }

    /// The palette is built once and kept: a text size or density change made while it exists
    /// must restyle the labels and placeholder it already has, not only new ones.
    @Test func anOpenPaletteFollowsALiveTextSizeChange() async throws {
        _ = NSApplication.shared
        let search = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        #expect(search.show(scope: PaletteScopeID.search))
        await search.model.settle()
        defer { search.closeForTest() }
        try Self.checkLiveTextSizeChange(search.model, rows: 0)
    }

    /// The same live change on a page with results: rows and section headers already configured
    /// at the old size pick up the new one through `reloadRows()`.
    @Test func openPaletteRowsFollowALiveTextSizeChange() async throws {
        _ = NSApplication.shared
        let commands = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        commands.show(.commands)
        await commands.model.settle()
        defer { commands.closeForTest() }
        try Self.checkLiveTextSizeChange(commands.model, rows: 5)
    }

    private static func checkLiveTextSizeChange(_ model: PaletteModel, rows: Int) throws {
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        let view = DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            let view = PaletteContentView(model: model)
            host(view, windows: &windows)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            return view
        }
        var large = DensityPreset.comfortable.tokens
        large.fontSize = 18
        try DensityTokens.$scoped.withValue(large) {
            view.render()
            view.window?.setContentSize(PaletteLayout.windowSize)
            _ = try check(view, "live Compact → Comfortable, 18 pt, \(rows) rows", rows: rows)
        }
    }

    private static func host(_ view: PaletteContentView, windows: inout [NSWindow]) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.contentView = view
        windows.append(window)
    }

    private static func check(_ model: PaletteModel, _ label: String, windows: inout [NSWindow], rows: Int) throws -> NSImage {
        let view = PaletteContentView(model: model)
        host(view, windows: &windows)
        return try check(view, label, rows: rows)
    }

    /// `rows`: at least that many labels besides the search bar's (a page with results).
    private static func check(_ view: PaletteContentView, _ label: String, rows: Int) throws -> NSImage {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let field = view.searchBar.field
        #expect(field.font?.pointSize == Typography.search.pointSize, "\(label): the field draws in the current search size")
        #expect(field.frame.minY >= -0.5 && field.frame.maxY <= view.searchBar.bounds.height + 0.5,
                "\(label): the field spans \(field.frame.minY)...\(field.frame.maxY) in a \(view.searchBar.bounds.height) pt bar")
        if field.stringValue.isEmpty {
            let placeholder = try #require(field.placeholderAttributedString, "\(label)")
            let placeholderFont = try #require(placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(placeholderFont.pointSize == Typography.search.pointSize, "\(label): the placeholder draws in the field's size")
            let style = placeholder.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.lineBreakMode == .byTruncatingTail, "\(label): a long placeholder truncates with an ellipsis, on one line")
        }

        try checkLongPlaceholder(width: view.searchBar.bounds.width, label)

        var labels = 0
        for text in textFields(in: view) where text !== field && !text.isHiddenOrHasHiddenAncestor && !text.stringValue.isEmpty {
            guard let parent = text.superview, let font = text.font else { continue }
            labels += 1
            if let style = (text as? PaletteLabel)?.fontSource?() {
                #expect(font.pointSize == style.pointSize, "\(label): \"\(text.stringValue)\" draws at \(font.pointSize) pt, its style is \(style.pointSize) pt")
            }
            #expect(text.frame.height >= PaletteText.height(text) - 0.5, "\(label): \"\(text.stringValue)\" is squeezed to \(text.frame.height) pt")
            #expect(text.frame.minY >= -0.5 && text.frame.maxY <= parent.bounds.height + 0.5,
                    "\(label): \"\(text.stringValue)\" spans \(text.frame.minY)...\(text.frame.maxY) in a \(parent.bounds.height) pt row")
            if isChrome(text) {
                // Chips and footer buttons are sized to their words; they never truncate them.
                let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                let natural = text.cell?.cellSize(forBounds: unbounded).width ?? 0
                #expect(text.frame.width >= natural - 0.5,
                        "\(label): \"\(text.stringValue)\" is \(text.frame.width) pt wide and needs \(natural) pt")
            }
        }
        #expect(labels > rows, "\(label): \(labels) labels")

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The issue's placeholder, in a search bar the palette's width: wider than its field at 20 pt
    /// (so the case is real), it must give way on one line inside the bar.
    private static func checkLongPlaceholder(width: CGFloat, _ label: String) throws {
        let bar = PaletteSearchBar(frame: NSRect(x: 0, y: 0, width: width, height: PaletteLayout.searchHeight))
        bar.update(query: "", placeholder: PaletteStrings.searchEverythingPlaceholder, chips: [], rootTitle: "", style: .token,
                   keywordHint: nil, isLoading: false)
        bar.layoutSubtreeIfNeeded()
        let field = bar.field
        let placeholder = try #require(field.placeholderAttributedString, "\(label)")
        let full = (PaletteStrings.searchEverythingPlaceholder as NSString).size(withAttributes: [.font: Typography.search]).width
        if label.contains("20 pt") {
            #expect(full > field.bounds.width, "\(label): placeholder \(full) pt in a \(field.bounds.width) pt field")
        }
        if full > field.bounds.width {
            // A scrolling cell clips mid-glyph instead of truncating, so the shown text must fit itself.
            #expect(placeholder.string.hasSuffix("…"), "\(label): \"\(placeholder.string)\" ends in an ellipsis")
            #expect(placeholder.size().width <= field.bounds.width,
                    "\(label): the shown placeholder is \(placeholder.size().width) pt in a \(field.bounds.width) pt field")
        }
        let style = placeholder.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byTruncatingTail, "\(label): the Search placeholder truncates with an ellipsis, on one line")
        #expect(field.frame.minY >= -0.5 && field.frame.maxY <= bar.bounds.height + 0.5,
                "\(label): the field spans \(field.frame.minY)...\(field.frame.maxY) in a \(bar.bounds.height) pt bar")
    }

    /// A label in the search bar (scope chips, breadcrumb) or the footer (page, crumbs, buttons).
    private static func isChrome(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0 is PaletteSearchBar || $0 is PaletteFooterView }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
    }

    private static func writeSheet(_ images: [(String, NSImage)]) throws {
        let columns = 2
        let cell = images.reduce(NSSize.zero) { NSSize(width: max($0.width, $1.1.size.width), height: max($0.height, $1.1.size.height)) }
        let label: CGFloat = 28
        let rows = (images.count + columns - 1) / columns
        let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(columns), height: (cell.height + label) * CGFloat(rows)))
        sheet.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
        for (index, (title, image)) in images.enumerated() {
            let x = CGFloat(index % columns) * cell.width
            let y = sheet.size.height - CGFloat(index / columns + 1) * (cell.height + label)
            image.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            (title as NSString).draw(at: NSPoint(x: x + 12, y: y + cell.height + 5), withAttributes: attributes)
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/palette-large-text.png").path
        let path = ProcessInfo.processInfo.environment["CMUX_PALETTE_LARGE_TEXT_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        try png.write(to: URL(fileURLWithPath: path))
    }
}
