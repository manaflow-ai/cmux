import Foundation

/// The selected DOM element and the context needed to implement its visual edits in source.
public struct BrowserDesignModeSelection: Codable, Equatable, Sendable {
    /// The primary robust CSS selector.
    public let selector: String
    /// Ordered fallback selectors used when an SPA replaces the selected node.
    public let selectors: [String]
    /// The lowercased DOM tag name.
    public let tagName: String
    /// A bounded outer-HTML snippet for the selected element.
    public let domSnippet: String
    /// The element text or form value before editing.
    public let textContent: String
    /// Whether the first slice can safely replace this element's text.
    public let textEditable: Bool
    /// The element's current viewport bounds.
    public let bounds: BrowserDesignModeRect
    /// The viewport associated with ``bounds``.
    public let viewport: BrowserDesignModeViewport
    /// The selected computed CSS properties before edits.
    public let computedStyles: [String: String]

    private enum CodingKeys: String, CodingKey {
        case selector
        case selectors
        case tagName = "tag_name"
        case domSnippet = "dom_snippet"
        case textContent = "text_content"
        case textEditable = "text_editable"
        case bounds
        case viewport
        case computedStyles = "computed_styles"
    }

    /// Creates selected-element context.
    /// - Parameters:
    ///   - selector: The primary selector.
    ///   - selectors: Ordered fallback selectors.
    ///   - tagName: The DOM tag name.
    ///   - domSnippet: The bounded outer-HTML snippet.
    ///   - textContent: The original text or form value.
    ///   - textEditable: Whether text replacement is safe.
    ///   - bounds: The element bounds.
    ///   - viewport: The viewport size.
    ///   - computedStyles: The selected computed CSS properties.
    public init(
        selector: String,
        selectors: [String],
        tagName: String,
        domSnippet: String,
        textContent: String,
        textEditable: Bool,
        bounds: BrowserDesignModeRect,
        viewport: BrowserDesignModeViewport,
        computedStyles: [String: String]
    ) {
        self.selector = selector
        self.selectors = selectors
        self.tagName = tagName
        self.domSnippet = domSnippet
        self.textContent = textContent
        self.textEditable = textEditable
        self.bounds = bounds
        self.viewport = viewport
        self.computedStyles = computedStyles
    }
}
