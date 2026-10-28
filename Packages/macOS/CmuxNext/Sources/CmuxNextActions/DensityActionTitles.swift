/// The words the palette's density rows share, for rows the App adds (one per custom density).
public nonisolated struct DensityActionTitles: Sendable {
    public init() {}

    /// "Density: ", localized with its separator; a custom density's row is this plus its name.
    public var prefix: String { DensityActionCatalog.densityPrefix }
}
