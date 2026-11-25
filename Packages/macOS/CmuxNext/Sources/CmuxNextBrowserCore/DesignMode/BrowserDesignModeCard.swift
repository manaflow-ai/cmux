public import CoreGraphics
public import Foundation

/// One design mode highlight as an agent chat's composer shows it: a text chip with what the agent
/// needs to find the element, and the element's place on the page for the screenshot crop.
public nonisolated struct BrowserDesignModeCard: Sendable, Equatable {
    /// Stable per element on a page, so the composer replaces the chip when it is highlighted again.
    public let id: String
    /// The chip's name, `Design: <tag> · <host>`.
    public let name: String
    /// What the agent reads: the page URL, selectors, XPath, text, DOM snippet, styles.
    public let text: String
    /// The element's rectangle in the viewport, in CSS pixels.
    public let bounds: CGRect
    /// The viewport's width in CSS pixels when the page measured `bounds`.
    public let viewportWidth: Double
    /// The gallery variation the highlight picks (a `cmux-variation-<n>` tile), nil for any other element.
    public var pickedVariation: Int?

    public init(id: String, name: String, text: String, bounds: CGRect, viewportWidth: Double, pickedVariation: Int? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.bounds = bounds
        self.viewportWidth = viewportWidth
        self.pickedVariation = pickedVariation
    }
}
