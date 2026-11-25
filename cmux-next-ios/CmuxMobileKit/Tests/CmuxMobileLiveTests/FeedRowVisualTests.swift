#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileDesign
import CmuxMobileMarkdown
import Testing
import UIKit

/// What a Feed row draws, read back from the real views (2026-11-18 iPhone report):
/// the "You" caption above your own message lines up with the message's text, and a
/// quote bubble keeps its dark fill after the app goes light and back to dark (the
/// app switcher's snapshots do that every time the app leaves the screen).
@MainActor
@Suite struct FeedRowVisualTests {
    static let width = 393

    static func quoted(_ author: FeedItem.Quote.Author = .you) -> FeedItem {
        FeedItem(id: "q", kind: .response, workspaceID: "w1", tabID: "t", agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: "Implemented both tools: 44 tests passed.",
                 quote: .init("Write a Brainfuck-to-C compiler and an optimizing interpreter in Python", author: author),
                 createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    static func layout(_ item: FeedItem) -> FeedRowLayout {
        let category = UIContentSizeCategory.large
        let key = FeedRowKey(item: item, state: FeedRowState(), width: width, textSize: category.rawValue)
        return FeedRowLayout.make(key, styles: NativeTextStyles(category: category), scale: 3)
    }

    /// The columns of `image` (points) in rows `band` that hold any ink.
    static func inkColumns(_ image: UIImage, rows band: ClosedRange<Int>) -> [Int] {
        guard let cg = image.cgImage else { return [] }
        let scale = Int(image.scale)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var columns = Set<Int>()
        for y in (band.lowerBound * scale)..<min(h, (band.upperBound + 1) * scale) {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 12 { columns.insert(x / scale) }
        }
        return columns.sorted()
    }

    /// The caption's ink, alone (the quote view with only its caption drawn).
    static func captionInk(_ part: FeedRowLayout.Quote) -> [Int] {
        let view = FeedQuoteView()
        view.apply(part, origin: .zero)
        view.layer.sublayers?.filter { !($0.delegate is UIView) }.forEach { $0.isHidden = true }
        view.subviews.forEach { $0.isHidden = true }
        let caption = view.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string.contains(part.caption.string) == true }
        caption?.isHidden = false
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        let band = Int(part.captionFrame.minY - part.frame.minY)...Int(part.captionFrame.maxY - part.frame.minY)
        return inkColumns(image, rows: band)
    }

    @Test func yourCaptionEndsWhereYourMessageTextEnds() throws {
        let part = try #require(Self.layout(Self.quoted()).quote)
        #expect(part.outgoing)
        let ink = Self.captionInk(part)
        let last = try #require(ink.last, "the caption draws")
        // In the quote view's coordinates: the bubble text's trailing edge (12 pt inside the bubble).
        let textEdge = part.textFrame.maxX - part.frame.minX
        #expect(abs(CGFloat(last + 1) - textEdge) <= 1.5,
                "\"You\" ends at \(last + 1) pt; the message text ends at \(textEdge) pt")
    }

    @Test func anAgentsCaptionStartsWhereItsMessageTextStarts() throws {
        let part = try #require(Self.layout(Self.quoted(.agent)).quote)
        let ink = Self.captionInk(part)
        let first = try #require(ink.first, "the caption draws")
        let textEdge = part.textFrame.minX - part.frame.minX
        #expect(abs(CGFloat(first) - textEdge) <= 1.5, "\"Asked you\" starts at \(first) pt; the text starts at \(textEdge) pt")
    }

    /// Whether two colors are the same sRGB color (a CGColor read back is not `==` its UIColor).
    static func same(_ a: UIColor?, _ b: UIColor) -> Bool {
        guard let a else { return false }
        var c1: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), c2 = c1
        a.getRed(&c1.0, green: &c1.1, blue: &c1.2, alpha: &c1.3)
        b.getRed(&c2.0, green: &c2.1, blue: &c2.2, alpha: &c2.3)
        return abs(c1.0 - c2.0) < 0.01 && abs(c1.1 - c2.1) < 0.01 && abs(c1.2 - c2.2) < 0.01 && abs(c1.3 - c2.3) < 0.01
    }

    /// The quote bubble's fill (the quote view's filled shape layer).
    static func bubbleFill(_ cell: UIView) -> UIColor? {
        func quote(in view: UIView) -> FeedQuoteView? {
            if let quote = view as? FeedQuoteView { return quote }
            for subview in view.subviews { if let found = quote(in: subview) { return found } }
            return nil
        }
        let shape = quote(in: cell)?.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.fillColor != nil }
        return shape?.fillColor.map { UIColor(cgColor: $0) }
    }

    static func settle(_ window: UIWindow) {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
    }

    @Test func aQuoteBubbleIsDarkAgainAfterTheAppGoesLightAndBack() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 800))
        window.overrideUserInterfaceStyle = .dark
        let cell = FeedRowCell(style: .default, reuseIdentifier: FeedRowCell.reuseID)
        let layout = Self.layout(Self.quoted())
        cell.frame = CGRect(x: 0, y: 0, width: CGFloat(Self.width), height: layout.height)
        window.addSubview(cell)
        window.isHidden = false
        Self.settle(window)
        cell.apply(layout, item: nil, settled: true)
        Self.settle(window)
        let dark = UIColor.cmuxMobileBubble.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = UIColor.cmuxMobileBubble.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        #expect(Self.same(Self.bubbleFill(cell), dark), "the dark fill at first, got \(String(describing: Self.bubbleFill(cell)))")
        // The switcher's snapshots: light, then back to dark.
        window.overrideUserInterfaceStyle = .light
        Self.settle(window)
        #expect(Self.same(Self.bubbleFill(cell), light), "the light fill while the app is light, got \(String(describing: Self.bubbleFill(cell)))")
        window.overrideUserInterfaceStyle = .dark
        Self.settle(window)
        #expect(Self.same(Self.bubbleFill(cell), dark), "the dark fill again, not the light one left behind, got \(String(describing: Self.bubbleFill(cell)))")
        window.isHidden = true
    }
}
#endif
