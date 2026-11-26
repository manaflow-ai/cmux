#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileDesign
import CmuxMobileMarkdown
import Testing
import UIKit

/// The Feed quote's caption ("Asked you" over the agent's question, "You" over your own message)
/// on the bubble's edge, in every case the row is drawn in (2026-11-24 report: the caption sat
/// 12 pt inside the bubble). The gallery records one PNG per case for the review page; the
/// check reads each caption's ink back from the real view.
@MainActor
@Suite struct FeedQuoteCaptionGalleryTests {
    static let widths = [375, 393, 440]
    static let sizes: [(String, UIContentSizeCategory)] = [
        ("default", .large), ("xxxl", .extraExtraExtraLarge), ("ax3", .accessibilityExtraLarge),
    ]
    static let texts = [
        ("short", "Ship it?"),
        ("long", "Should I keep the old route as a redirect, or drop it and update every link in the docs and the changelog too?"),
    ]
    static let authors: [(String, FeedItem.Quote.Author)] = [("agent", .agent), ("you", .you)]

    static func item(_ text: String, _ author: FeedItem.Quote.Author) -> FeedItem {
        FeedItem(id: "q", kind: .response, workspaceID: "w1", tabID: "t", agentName: "Codex", harness: "codex",
                 workspaceTitle: "cmux.com", markdown: "Kept it as a 301 to the new route.",
                 quote: .init(text, author: author), createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    static func layout(_ item: FeedItem, width: Int, category: UIContentSizeCategory) -> FeedRowLayout {
        let key = FeedRowKey(item: item, state: FeedRowState(), width: width, textSize: category.rawValue)
        return FeedRowLayout.make(key, styles: NativeTextStyles(category: category), scale: 3)
    }

    static func render(_ layout: FeedRowLayout, width: Int, category: UIContentSizeCategory, dark: Bool) -> UIImage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: CGFloat(width), height: layout.height))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = .systemBackground
        let cell = FeedRowCell(style: .default, reuseIdentifier: FeedRowCell.reuseID)
        cell.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: layout.height)
        window.addSubview(cell)
        window.isHidden = false
        FeedRowVisualTests.settle(window)
        cell.apply(layout, item: nil, settled: true)
        FeedRowVisualTests.settle(window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(preferredContentSizeCategory: category),
        ])
        var image = UIImage()
        traits.performAsCurrent {
            image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                UIColor.systemBackground.resolvedColor(with: traits).setFill()
                context.fill(window.bounds)
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        return image
    }

    @Test func gallery() {
        for (authorName, author) in Self.authors {
            for (textName, text) in Self.texts {
                for width in Self.widths {
                    for (sizeName, category) in Self.sizes {
                        let layout = Self.layout(Self.item(text, author), width: width, category: category)
                        for dark in [false, true] {
                            let image = Self.render(layout, width: width, category: category, dark: dark)
                            let name = "feedquote_\(authorName)_\(textName)_\(width)_\(sizeName)_\(dark ? "dark" : "light").png"
                            if let png = image.pngData() { Attachment.record(png, named: name) }
                        }
                    }
                }
            }
        }
    }

    @Test func everyCaptionSitsOnItsBubbleEdge() throws {
        for (authorName, author) in Self.authors {
            for (textName, text) in Self.texts {
                for width in Self.widths {
                    for (sizeName, category) in Self.sizes {
                        let part = try #require(Self.layout(Self.item(text, author), width: width, category: category).quote)
                        let ink = FeedRowVisualTests.captionInk(part)
                        let label = "\(authorName) \(textName) \(width) \(sizeName)"
                        if author == .you {
                            let last = try #require(ink.last, "\(label): the caption draws")
                            let edge = part.bubble.maxX - part.frame.minX
                            #expect(abs(CGFloat(last + 1) - edge) <= 1.5, "\(label): \"You\" ends at \(last + 1) pt; the bubble ends at \(edge) pt")
                        } else {
                            let first = try #require(ink.first, "\(label): the caption draws")
                            let edge = part.bubble.minX - part.frame.minX
                            #expect(abs(CGFloat(first) - edge) <= 1.5, "\(label): \"Asked you\" starts at \(first) pt; the bubble starts at \(edge) pt")
                        }
                    }
                }
            }
        }
    }
}
#endif
