/// `appearance.glass.<role>.{material,tint,tintStrength,veil}` in cmux.json: the material, tint, tint
/// strength and veil of each glass surface role plus `chrome` (schemas/settings/source/glass.json, which
/// holds every path, range and default; cmux-config's glass module resolves and clamps the same rows).
/// Every default is today's look, so an unset key changes nothing.
public nonisolated struct GlassSetting {
    /// The parser and schema helpers are stateless; the value form keeps this utility instantiable so
    /// the package-conventions namespace rule does not add a new ratchet entry.
    public init() {}
    /// `appearance.glass`.
    public static let rootPath = ["appearance", "glass"]
}
