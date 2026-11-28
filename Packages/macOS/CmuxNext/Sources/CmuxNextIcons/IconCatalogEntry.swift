/// One row of Resources/icon-catalog.json.
public nonisolated struct IconCatalogEntry: Hashable, Sendable, Decodable {
    public var name: IconName
    public var meaning: String
    /// SF Symbol drawn when the pack lacks the icon.
    public var sf: String
    public var family: String
    /// The style rows below `CGFloat.iconDenseThreshold` use, when set.
    public var denseStyle: IconStyle?

    public init(name: IconName, meaning: String, sf: String, family: String, denseStyle: IconStyle? = nil) {
        self.name = name
        self.meaning = meaning
        self.sf = sf
        self.family = family
        self.denseStyle = denseStyle
    }
}
