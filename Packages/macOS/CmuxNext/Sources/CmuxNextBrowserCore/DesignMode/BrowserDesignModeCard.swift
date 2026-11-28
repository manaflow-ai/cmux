public import CoreGraphics
public import Foundation

/// One design mode highlight as an agent chat's composer shows it: a text chip with what the agent
/// needs to find the element, and the element's place on the page for the screenshot crop.
public nonisolated struct BrowserDesignModeCard: Sendable, Equatable {
    /// Stable per element on a page, so the composer replaces the chip when it is highlighted again.
    public let id: String
    /// The chip's name: `<number> · <comment>`, or `<number> · <tag> · <host>` with no comment.
    public let name: String
    /// What the agent reads: the page URL, selectors, XPath, text, DOM snippet, styles.
    public let text: String
    /// The element's rectangle in the viewport, in CSS pixels.
    public let bounds: CGRect
    /// The viewport's width in CSS pixels when the page measured `bounds`.
    public let viewportWidth: Double
    /// The gallery variation the highlight picks (a `cmux-variation-<n>` tile), nil for any other element.
    public var pickedVariation: Int?
    /// What the person wrote in the pick's comment bubble; empty when they added it without one.
    public var comment: String
    /// The pick's number, as its pin on the page shows it (1 for the first pick).
    public var number: Int
    /// The pick's page selector (its key on the page); a browser comment thread names it.
    public var selector: String
    /// The picked element's text, trimmed (a browser comment's `quote`); empty for a drawn region.
    public var quote: String

    public init(id: String, name: String, text: String, bounds: CGRect, viewportWidth: Double, pickedVariation: Int? = nil,
                comment: String = "", number: Int = 1, selector: String = "", quote: String = "") {
        self.id = id
        self.name = name
        self.text = text
        self.bounds = bounds
        self.viewportWidth = viewportWidth
        self.pickedVariation = pickedVariation
        self.comment = comment
        self.number = number
        self.selector = selector
        self.quote = quote
    }

    /// The id of the card for the pick at `selector` on `pageURL`, the same on every launch (FNV-1a;
    /// Swift's `hashValue` is seeded per process): a kept comment thread put back on its element is
    /// held under it before the page reports the pick, so the pick gets no chip.
    public static func id(selector: String, pageURL: URL?) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (selector + "|" + (pageURL?.absoluteString ?? "")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "design-" + String(hash, radix: 16)
    }
}
