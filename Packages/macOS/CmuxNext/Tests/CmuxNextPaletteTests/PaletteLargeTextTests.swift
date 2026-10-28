import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import Foundation
import Testing

/// #26606: with a large text size the palette's search field and rows kept the density's heights,
/// so the text was clipped top and bottom, and the long Search placeholder ran off its row. At every
/// density, with the largest Interface Size (16 pt) and the largest density text size (20 pt), each
/// label must sit inside its row at its full height, and the placeholder must truncate.
///
/// Also draws every case into one PNG (`CMUX_PALETTE_LARGE_TEXT_SNAPSHOT_PATH`, else
/// `.build/palette-large-text.png` in the package) for the PR.
@MainActor
@Suite(.paletteRanker)
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
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        #expect(palette.show(scope: PaletteScopeID.search))
        await palette.model.settle()
        defer { palette.hide() }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        var images: [(String, NSImage)] = []
        for item in Self.cases {
            let image = try DensityTokens.$scoped.withValue(item.tokens) {
                try Self.check(palette.model, item.label, windows: &windows)
            }
            images.append((item.label, image))
        }
        try Self.writeSheet(images)
    }

    private static func check(_ model: PaletteModel, _ label: String, windows: inout [NSWindow]) throws -> NSImage {
        let view = PaletteContentView(model: model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let field = view.searchBar.field
        let placeholder = try #require(field.placeholderAttributedString, "\(label)")
        let placeholderFont = try #require(placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(placeholderFont.pointSize == Typography.search.pointSize, "\(label): the placeholder draws in the field's size")
        let style = placeholder.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byTruncatingTail, "\(label): a long placeholder truncates with an ellipsis")
        let placeholderHeight = ceil(placeholder.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        #expect(field.frame.height >= placeholderHeight, "\(label): field \(field.frame.height) pt, placeholder \(placeholderHeight) pt")

        var labels = 0
        for text in textFields(in: view) where !text.isHiddenOrHasHiddenAncestor && !text.stringValue.isEmpty {
            guard let parent = text.superview, let font = text.font else { continue }
            labels += 1
            let natural = ceil(font.ascender - font.descender)
            #expect(text.frame.height >= natural, "\(label): \"\(text.stringValue)\" is \(text.frame.height) pt for \(natural) pt text")
            #expect(text.frame.minY >= -0.5 && text.frame.maxY <= parent.bounds.height + 0.5,
                    "\(label): \"\(text.stringValue)\" spans \(text.frame.minY)...\(text.frame.maxY) in a \(parent.bounds.height) pt row")
        }
        #expect(labels > 5, "\(label): the palette shows rows")

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
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
