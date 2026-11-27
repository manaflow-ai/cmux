import Foundation

/// The selected DOM element and the context needed to implement its visual edits in source.
public struct BrowserDesignModeSelection: Codable, Equatable, Sendable {
    /// The primary robust CSS selector.
    public let selector: String
    /// Ordered fallback selectors used when an SPA replaces the selected node.
    public let selectors: [String]
    /// Absolute XPath (id-anchored when possible); the primary human-facing identity.
    public let xpath: String
    /// Palette hex color (#RRGGBB) shared by the page outline and composer pill.
    public let color: String
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
    /// Nearest named React components from the fiber tree, when detectable.
    public let reactComponents: [String]
    /// Prop keys of the nearest React component (never prop values).
    public let reactPropKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case selector
        case selectors
        case xpath
        case color
        case tagName = "tag_name"
        case domSnippet = "dom_snippet"
        case textContent = "text_content"
        case textEditable = "text_editable"
        case bounds
        case viewport
        case computedStyles = "computed_styles"
        case reactComponents = "react_components"
        case reactPropKeys = "react_prop_keys"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selector = try container.decode(String.self, forKey: .selector)
        // Every collection/string field tolerates omission: the prompt payload
        // leaves empty fields out entirely to stay small.
        selectors = try container.decodeIfPresent([String].self, forKey: .selectors) ?? []
        xpath = try container.decodeIfPresent(String.self, forKey: .xpath) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        tagName = try container.decode(String.self, forKey: .tagName)
        domSnippet = try container.decodeIfPresent(String.self, forKey: .domSnippet) ?? ""
        textContent = try container.decodeIfPresent(String.self, forKey: .textContent) ?? ""
        textEditable = try container.decodeIfPresent(Bool.self, forKey: .textEditable) ?? false
        bounds = try container.decode(BrowserDesignModeRect.self, forKey: .bounds)
        viewport = try container.decode(BrowserDesignModeViewport.self, forKey: .viewport)
        computedStyles = try container.decodeIfPresent([String: String].self, forKey: .computedStyles) ?? [:]
        reactComponents = try container.decodeIfPresent([String].self, forKey: .reactComponents) ?? []
        reactPropKeys = try container.decodeIfPresent([String].self, forKey: .reactPropKeys) ?? []
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
        xpath: String = "",
        color: String = "",
        tagName: String,
        domSnippet: String,
        textContent: String,
        textEditable: Bool,
        bounds: BrowserDesignModeRect,
        viewport: BrowserDesignModeViewport,
        computedStyles: [String: String],
        reactComponents: [String] = [],
        reactPropKeys: [String] = []
    ) {
        self.selector = selector
        self.selectors = selectors
        self.xpath = xpath
        self.color = color
        self.tagName = tagName
        self.domSnippet = domSnippet
        self.textContent = textContent
        self.textEditable = textEditable
        self.bounds = bounds
        self.viewport = viewport
        self.computedStyles = computedStyles
        self.reactComponents = reactComponents
        self.reactPropKeys = reactPropKeys
    }
}
