/// One row of Resources/icon-catalog.json.
public nonisolated struct IconCatalogEntry: Hashable, Sendable, Decodable {
    public var name: IconName
    public var meaning: String
    /// SF Symbol drawn when the pack lacks the icon.
    public var sf: String
    public var family: String
    /// The style rows below `CGFloat.iconDenseThreshold` use, when set.
    public var denseStyle: IconStyle?
    /// Where the drawing comes from when cmux did not draw it: `"chromium"` for Chrome's own
    /// icons (design/icons/chromium, BSD-3-Clause), nil for cmux's.
    public var source: String?
    /// Whether this icon stands for its `sf` symbol in `IconCatalog.name(forSymbol:)`. False when
    /// `sf` is only the fallback (Chromium icons), so asking for that symbol elsewhere in the app
    /// keeps drawing cmux's icon for it.
    public var aliasesSymbol: Bool

    public init(name: IconName, meaning: String, sf: String, family: String, denseStyle: IconStyle? = nil,
                source: String? = nil, aliasesSymbol: Bool = true) {
        self.name = name
        self.meaning = meaning
        self.sf = sf
        self.family = family
        self.denseStyle = denseStyle
        self.source = source
        self.aliasesSymbol = aliasesSymbol
    }

    /// Whether the drawing is Chrome's, from Chromium's vector icons.
    public var isChromium: Bool { source == "chromium" }

    private enum CodingKeys: String, CodingKey {
        case name, meaning, sf, family, denseStyle, source
        case aliasesSymbol = "alias"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(IconName.self, forKey: .name),
            meaning: try container.decode(String.self, forKey: .meaning),
            sf: try container.decode(String.self, forKey: .sf),
            family: try container.decode(String.self, forKey: .family),
            denseStyle: try container.decodeIfPresent(IconStyle.self, forKey: .denseStyle),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            aliasesSymbol: try container.decodeIfPresent(Bool.self, forKey: .aliasesSymbol) ?? true
        )
    }
}
