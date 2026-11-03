import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The omnibar's placeholder sits on the line the caret and typed text use, centered in the bar, at
/// every density, focused or not: AppKit's string drawing put it 3 pt high in Comfortable, above
/// the caret, the magnifier and the shortcut badge.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarPlaceholderAlignmentTests {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The ink box of the field's placeholder (or typed `text`) in a bar of `metrics.barHeight`.
    private static func ink(_ metrics: OmnibarMetrics, placeholder: String, text: String, focused: Bool) throws -> NSRect {
        _ = NSApplication.shared
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: metrics.barHeight))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        let field = AddressField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = true
        field.font = Typography.system(size: metrics.fontSize, weight: TypeScale.regular)
        field.textColor = .black
        field.setPlaceholder(placeholder)
        field.stringValue = text
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 0, y: (host.bounds.height - height) / 2, width: host.bounds.width, height: height)
        host.addSubview(field)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        host.addSubview(other)
        window.makeFirstResponder(focused ? field : other)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        var minY = Int.max, maxY = -1
        // Past the caret at the text's start.
        for y in 0..<rep.pixelsHigh {
            for x in Int(8 * scale)..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxY >= 0, "nothing drew")
        return NSRect(x: 0, y: CGFloat(minY) / scale, width: 1, height: CGFloat(maxY - minY + 1) / scale)
    }

    @Test(arguments: [DensityPreset.compact, .comfortable])
    func placeholderIsOnTheCaretLineAndCentered(preset: DensityPreset) throws {
        let metrics = OmnibarMetrics(tokens: preset.tokens)
        // Capitals only: their ink box is the line's optical middle, with no descender.
        let words = "HHHHHHHH"
        let typed = try Self.ink(metrics, placeholder: "", text: words, focused: true)
        for focused in [true, false] {
            let drawn = try Self.ink(metrics, placeholder: words, text: "", focused: focused)
            #expect(abs(drawn.midY - typed.midY) <= 0.5, "\(preset) focused=\(focused): \(drawn) vs typed \(typed)")
            #expect(abs(drawn.midY - metrics.barHeight / 2) <= 1, "\(preset) focused=\(focused): \(drawn) in a \(metrics.barHeight) pt bar")
        }
    }

    @Test func thePlaceholderStaysOffAppKitsCell() throws {
        _ = NSApplication.shared
        let field = AddressField(frame: .zero)
        field.setPlaceholder("Search")
        let cell = try #require(field.cell as? AddressFieldCell)
        #expect(cell.drawnPlaceholder?.string == "Search")
        #expect(cell.placeholderAttributedString == nil)
    }
}
