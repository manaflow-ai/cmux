import CoreText

/// Resolves PostScript names through CoreText against the fonts installed on this Mac.
public struct CoreTextFontFamilyResolver: FontFamilyResolving {
    /// Creates a resolver.
    public init() {}

    /// The family of the installed font with exactly this PostScript name.
    ///
    /// CoreText substitutes a fallback font for unknown names, so the created
    /// font's own PostScript name must match before its family is trusted.
    public func familyName(forPostScriptName postScriptName: String) -> String? {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard (CTFontCopyPostScriptName(font) as String) == postScriptName else { return nil }
        return CTFontCopyFamilyName(font) as String
    }
}
