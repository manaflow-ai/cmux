#if os(iOS)
import CmuxMobileMarkdown
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Aziz 2026-11-16 ("align the bullet points center with the center of the text row"): in a
/// native answer row, a list item's bullet sat above its first line, more the longer the item
/// (a nine-line item's bullet floated a line above its text). The item's label was sized with
/// the font's leading on every line, which UILabel does not draw, so UILabel centered the text
/// in the taller frame and pushed its first line down. A bullet (or number) is now centered on
/// its item's first line, whatever the item's length or depth.
@MainActor
@Suite struct ListMarkerAlignmentTests {
    static let items: [MarkdownList.Item] = [
        .init(text: "**The cause:** each time a streaming reply settles at the bottom, `retainScrollOrigin` writes a style value onto "
            + "the transcript's scroll area. That makes the browser restyle 1,500–1,970 elements, which accounts for 92–96% of all "
            + "restyling during a stream: 24.4 ms of style work per key. The very next line reads the scroll position, which forces "
            + "that work to happen immediately. That's the \"22 ms forced layout\".", depth: 0, ordinal: nil, checked: nil),
        .init(text: "**So far:** a first attempt cut it to 380 elements and 12.9 ms per key. The goal is one element per write.",
              depth: 0, ordinal: nil, checked: nil),
        .init(text: "**Next to merge:**", depth: 0, ordinal: nil, checked: nil),
        .init(text: "#44430, which takes rebuilds while trimming a long chat from 8 to 0", depth: 1, ordinal: nil, checked: nil),
        .init(text: "#44360", depth: 1, ordinal: nil, checked: nil),
        .init(text: "A numbered step whose text runs onto a second and a third line at this width, so its number is checked too.",
              depth: 0, ordinal: 2, checked: nil),
    ]

    static func cell(width: CGFloat, category: UIContentSizeCategory, style: UIUserInterfaceStyle) throws -> ChatNativeRowCell {
        let environment = ChatNativeEnvironment(width: width, category: category, wrapCode: false)
        let kind = MarkdownBlock.Kind.list(MarkdownList(items: items))
        let layout = try #require(ChatNativeLayout.make(.block(messageID: "m", block: MarkdownBlock(id: 0, kind: kind)), id: "m#0",
                                                        expanded: false, environment: environment))
        let cell = ChatNativeRowCell(frame: CGRect(x: 0, y: 0, width: width + 40, height: layout.height))
        cell.overrideUserInterfaceStyle = style
        cell.apply(layout, actions: ChatNativeActions())
        cell.layoutIfNeeded()
        return cell
    }

    /// Where a label draws its first line's top: UILabel centers its text in a taller frame.
    static func firstLineTop(_ label: UILabel) -> CGFloat {
        let drawn = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: 0).height
        return label.frame.minY + max(0, label.bounds.height - drawn) / 2
    }

    @Test(arguments: [UIContentSizeCategory.large, .extraExtraLarge])
    func eachMarkerSitsOnItsItemsFirstLine(category: UIContentSizeCategory) throws {
        let cell = try Self.cell(width: 350, category: category, style: .dark)
        let labels = cell.contentView.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden && ($0.attributedText?.length ?? 0) > 0 }
        let markers = labels.filter { ChatNativeRowCell.isListMarker($0.attributedText?.string ?? "") }
        let texts = labels.filter { !ChatNativeRowCell.isListMarker($0.attributedText?.string ?? "") }
        #expect(markers.count == Self.items.count)
        #expect(texts.count == Self.items.count)
        for marker in markers {
            // The item that starts on the marker's row: the nearest label to its right.
            let item = try #require(texts.filter { $0.frame.minX > marker.frame.maxX }
                .min { abs($0.frame.minY - marker.frame.minY) < abs($1.frame.minY - marker.frame.minY) })
            let lines = Int((item.bounds.height / (item.font.lineHeight + 5)).rounded(.up))
            let gap = Self.firstLineTop(item) - Self.firstLineTop(marker)
            #expect(abs(gap) <= 0.34, "marker \(marker.attributedText?.string ?? "") is \(gap) pt off its item's first line (\(lines) lines: \(item.text ?? ""))")
        }
        Self.recordShots(category: category)
    }

    /// Items are 8 pt apart, as `MarkdownListView`, however many lines the one above runs to: the
    /// font leading UILabel does not draw is not left as extra space under a long item.
    @Test func itemsAreEightPointsApart() throws {
        let cell = try Self.cell(width: 350, category: .large, style: .dark)
        let texts = cell.contentView.subviews.compactMap { $0 as? UILabel }
            .filter { !$0.isHidden && ($0.attributedText?.length ?? 0) > 0 && !ChatNativeRowCell.isListMarker($0.attributedText?.string ?? "") }
            .sorted { $0.frame.minY < $1.frame.minY }
        #expect(texts.count == Self.items.count)
        for (above, below) in zip(texts, texts.dropFirst()) {
            let gap = below.frame.minY - above.frame.maxY
            #expect(abs(gap - 8) <= 0.34, "\(gap) pt under \(above.text ?? "")")
        }
    }

    /// A tap on a link opens it where UILabel draws it, also on the last line of a long item: the
    /// hit test laid the text out with the font leading UILabel leaves out, a line lower by the
    /// end of a long item, so a tap on the link's line found the plain line above it.
    @Test func aLinkOnALongItemsLastLineOpensWhereItIsDrawn() throws {
        let url = "https://example.com/last-line"
        let item = MarkdownList.Item(text: String(repeating: "plain words on this line ", count: 70) + "\n[openme](\(url))",
                                     depth: 0, ordinal: nil, checked: nil)
        let environment = ChatNativeEnvironment(width: 350, category: .large, wrapCode: false)
        let kind = MarkdownBlock.Kind.list(MarkdownList(items: [item]))
        let layout = try #require(ChatNativeLayout.make(.block(messageID: "m", block: MarkdownBlock(id: 0, kind: kind)), id: "m#0",
                                                        expanded: false, environment: environment))
        let cell = ChatNativeRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: layout.height))
        cell.apply(layout, actions: ChatNativeActions())
        cell.layoutIfNeeded()
        let label = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first { $0.text?.contains("openme") == true })
        let font = try #require(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let drawn = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: 0).height
        let textTop = label.frame.minY + max(0, label.bounds.height - drawn) / 2
        let lastLine = CGPoint(x: label.frame.minX + 12, y: textTop + drawn - font.lineHeight / 2)
        let lineAbove = CGPoint(x: lastLine.x, y: lastLine.y - font.lineHeight - 5)
        let lines = Int((drawn / (font.lineHeight + 5)).rounded())
        #expect(lines >= 15, "the item runs to \(lines) lines")
        #expect(cell.link(at: lastLine)?.absoluteString == url, "a tap on the link's line (\(lines) lines down)")
        #expect(cell.link(at: lineAbove) == nil, "a tap on the plain line above it")
    }

    /// The row as drawn, on the chat's background, in both looks, attached to the result bundle for
    /// the PR's before and after. The cell is hosted in a window of the shot's look: outside a window
    /// its labels resolve `.label` in the light look whatever the cell's override (a dark shot drew
    /// black text on black). The dark shot must have light text, so a blank capture fails.
    static func recordShots(category: UIContentSizeCategory) {
        for style in [UIUserInterfaceStyle.dark, .light] {
            guard let cell = try? cell(width: 350, category: category, style: style) else { continue }
            let rect = CGRect(x: 0, y: 0, width: cell.bounds.width, height: cell.bounds.height)
            let window = UIWindow(frame: rect)
            window.overrideUserInterfaceStyle = style
            window.backgroundColor = style == .dark ? .black : .white
            window.addSubview(cell)
            window.isHidden = false
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            // `drawHierarchy` draws nothing in the test host (a transparent image), so render the
            // layer tree, each label drawn again under the window's look.
            for label in cell.contentView.subviews.compactMap({ $0 as? UILabel }) {
                label.setNeedsDisplay()
                label.layer.displayIfNeeded()
            }
            let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { context in
                (style == .dark ? UIColor.black : UIColor.white).setFill()
                context.fill(rect)
                window.traitCollection.performAsCurrent { cell.layer.render(in: context.cgContext) }
            }
            window.isHidden = true
            if style == .dark {
                #expect(Self.brightFraction(image) > 0.005, "the dark shot draws its text light on black")
            }
            let name = "list-\(category == .large ? "large" : "xxl")-\(style == .dark ? "dark" : "light").png"
            if let png = image.pngData() { Attachment.record(png, named: name) }
        }
    }

    /// The share of pixels brighter than 70% gray.
    static func brightFraction(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var bright = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) > 535 {
            bright += 1
        }
        return Double(bright) / Double(width * height)
    }
}
#endif
