public import CoreText

/// Font-resolution seam used by ``GhosttyConfigDiscovery`` to mirror Ghostty's
/// CoreText family-name discovery when validating and resolving the CJK
/// `font-codepoint-map` fallback it auto-injects.
///
/// Injecting this inverts the direct CoreText `CTFont*` global calls the
/// discovery logic used to perform, so tests can supply deterministic font
/// answers instead of depending on the installed system fonts.
public protocol GhosttyFontProbing {
    /// Resolves a font by family name and optional weight trait, mirroring
    /// Ghostty's `CTFontCollection` family-name discovery path. Returns `nil`
    /// when no matching family is found.
    func discoveredFont(named name: String, size: CGFloat, weightTrait: CGFloat?) -> CTFont?

    /// Returns a `CTFont` for `name` only when one of its resolved family,
    /// full, or PostScript names matches the requested name (normalized);
    /// otherwise `nil`.
    func configuredFont(named name: String, size: CGFloat) -> CTFont?
}

/// Default ``GhosttyFontProbing`` conformer backed by CoreText.
///
/// Performs the exact `CTFontDescriptor` / `CTFontCollection` / `CTFontCopyName`
/// lookups the discovery logic previously inlined, so injected CJK font names
/// resolve identically to the app's prior behavior.
public struct CoreTextGhosttyFontProbe: GhosttyFontProbing {
    /// Creates a CoreText-backed font probe.
    public init() {}

    public func discoveredFont(named name: String, size: CGFloat, weightTrait: CGFloat?) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: trimmed,
            kCTFontSizeAttribute: size,
        ]
        if let weightTrait {
            attributes[kCTFontTraitsAttribute] = [
                kCTFontWeightTrait: weightTrait,
            ] as CFDictionary
        }

        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let match = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor])?.first else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(match, size, nil)
    }

    public func configuredFont(named name: String, size: CGFloat) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateWithName(trimmed as CFString, size, nil)
        let normalizedRequestedName = GhosttyConfigDiscovery.normalizedFontName(trimmed)
        let resolvedNames = [
            kCTFontFamilyNameKey,
            kCTFontFullNameKey,
            kCTFontPostScriptNameKey,
        ].compactMap { CTFontCopyName(font, $0) as String? }

        guard resolvedNames.contains(where: { GhosttyConfigDiscovery.normalizedFontName($0) == normalizedRequestedName }) else {
            return nil
        }

        return font
    }
}
