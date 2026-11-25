import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// The palette's search row puts the magnifier, the placeholder ("Search for commands…"), the
/// caret and typed text on one line, centered in the row, as Spotlight and Raycast do (Lawrence
/// 2026-10-29: "search for commands is not vertically centered"). The field editor drew the
/// placeholder in the bundled Inter 4 pt above the magnifier and the caret, with the field frame
/// itself centered: the editor's placeholder used string drawing, typed text TextKit.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaletteSearchCenteringTests {
    static let placeholder = "Search for commands…"

    /// The ink rows (top and bottom, in points from the bar's top) of what the bar draws in the
    /// columns `xRange`, or nil when nothing there has ink.
    private static func inkRows(_ rep: NSBitmapImageRep, scale: CGFloat, xRange: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        var top: Int?
        var bottom: Int?
        let x0 = max(0, Int((xRange.lowerBound * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide - 1, Int((xRange.upperBound * scale).rounded(.up)))
        for y in 0..<rep.pixelsHigh {
            for x in x0...x1 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                if top == nil { top = y }
                bottom = y
                break
            }
        }
        guard let top, let bottom else { return nil }
        return CGFloat(top) / scale...CGFloat(bottom + 1) / scale
    }

    private struct Drawn {
        let bar: NSRect
        let magnifier: ClosedRange<CGFloat>
        let text: ClosedRange<CGFloat>
        /// The leftmost ink right of the magnifier: the first letter's left edge.
        let textMinX: CGFloat
        /// The x of the line's start, where the caret of the empty field sits, from the field
        /// editor's layout (the caret is not in a cached drawing).
        let caretX: CGFloat
    }

    /// The leftmost column with ink at or right of `x`.
    private static func inkMinX(_ rep: NSBitmapImageRep, scale: CGFloat, from x: CGFloat) -> CGFloat? {
        for column in Int((x * scale).rounded(.up))..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: column, y: y)?.alphaComponent ?? 0) > 0.15 {
                return CGFloat(column) / scale
            }
        }
        return nil
    }

    /// Lays the bar out at the palette's width and search height, in a key window with the field
    /// editing (as when the palette is open), and measures the magnifier's and the text's ink.
    private static func draw(query: String, appearance: NSAppearance.Name) throws -> Drawn {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: PaletteLayout.width, height: PaletteLayout.searchHeight)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        defer { window.close() }
        let bar = PaletteSearchBar(frame: frame)
        window.contentView = bar
        bar.update(query: query, placeholder: placeholder, chips: [], rootTitle: "Commands", style: .token,
                   keywordHint: nil, isLoading: false)
        bar.layoutSubtreeIfNeeded()
        window.makeFirstResponder(bar.field)
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        // The caret where the palette leaves it, at the end; the line's start x comes from the layout.
        editor.selectedRange = NSRange(location: query.utf16.count, length: 0)
        bar.layoutSubtreeIfNeeded()
        bar.displayIfNeeded()
        let rep = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: rep)
        // Read after the drawing: forcing the editor's layout before it moved the typed line 3 pt.
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let line = editor.string.isEmpty ? layout.extraLineFragmentRect : layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let caretX = editor.convert(NSPoint(x: line.minX + container.lineFragmentPadding + editor.textContainerOrigin.x, y: 0), to: bar).x
        let scale = CGFloat(rep.pixelsWide) / bar.bounds.width
        let icon = bar.subviews.first { $0 is NSImageView && !$0.isHidden }
        let iconFrame = try #require(icon?.frame)
        // Columns of the text past the caret at its start, short of the caret at its end.
        let field = bar.field.frame
        let text = (field.minX + 6)...(field.minX + 60)
        return Drawn(bar: bar.bounds,
                     magnifier: try #require(inkRows(rep, scale: scale, xRange: iconFrame.minX...iconFrame.maxX)),
                     text: try #require(inkRows(rep, scale: scale, xRange: text)),
                     textMinX: try #require(inkMinX(rep, scale: scale, from: iconFrame.maxX + 1)),
                     caretX: caretX)
    }

    private static func center(_ range: ClosedRange<CGFloat>) -> CGFloat { (range.lowerBound + range.upperBound) / 2 }

    /// "Search" has no descender, so its ink center is the cap-height center the eye centers.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func thePlaceholderSitsOnTheMagnifiersCenterLine(appearance: NSAppearance.Name) throws {
        let drawn = try Self.draw(query: "", appearance: appearance)
        let tolerance: CGFloat = 1
        #expect(abs(Self.center(drawn.text) - Self.center(drawn.magnifier)) <= tolerance,
                "placeholder ink \(drawn.text) vs magnifier \(drawn.magnifier)")
        #expect(abs(Self.center(drawn.text) - drawn.bar.midY) <= tolerance,
                "placeholder ink \(drawn.text) vs bar center \(drawn.bar.midY)")
    }

    /// Typing replaces the placeholder in place: the line keeps its height.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func typedTextTakesThePlaceholdersPlace(appearance: NSAppearance.Name) throws {
        let empty = try Self.draw(query: "", appearance: appearance)
        let typed = try Self.draw(query: Self.placeholder, appearance: appearance)
        // Centers, not edges: the placeholder's tertiary ink loses its faint anti-aliased top row to
        // the ink threshold, which typed text in the primary color keeps.
        #expect(abs(Self.center(empty.text) - Self.center(typed.text)) <= 0.75, "placeholder \(empty.text) vs typed \(typed.text)")
    }

    /// The caret of the empty field sits at the placeholder's left edge, just left of its "S"
    /// (Lawrence 2026-11-02: "blinking cursor is not fully on left of S of Search"), and the typed
    /// "S" starts where the placeholder's did.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theCaretSitsLeftOfThePlaceholdersFirstLetter(appearance: NSAppearance.Name) throws {
        let empty = try Self.draw(query: "", appearance: appearance)
        let typed = try Self.draw(query: Self.placeholder, appearance: appearance)
        let bearing = empty.textMinX - empty.caretX
        #expect(bearing >= -0.25 && bearing <= 1.5, "placeholder S at \(empty.textMinX), caret at \(empty.caretX)")
        // One pixel at 1x: the tertiary placeholder's faint first column can fall under the ink threshold.
        #expect(abs(empty.textMinX - typed.textMinX) <= 1, "placeholder S at \(empty.textMinX), typed S at \(typed.textMinX)")
    }
}
