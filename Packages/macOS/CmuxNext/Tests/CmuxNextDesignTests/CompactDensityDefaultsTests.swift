import CmuxNextDesign
import Testing

/// User 2026-11-19 (msg 40580): "here should be new defaults for compact: // Compact Custom: level 0.15, spacing 0.9,
/// fontSize 12.6", then every value below. Compact ships exactly his tuned density; the other densities keep theirs.
struct CompactDensityDefaultsTests {
    static let tuned: [String: Double] = [
        "browserRowGap": 1, "browserRowHeight": 28, "chatEditorMin": 31.5, "composerZoom": 0.9, "densityScale": 0.9,
        "omnibarButtonSpacing": 2.5, "omnibarCornerRadius": 8, "omnibarEdgeInset": 2, "omnibarExtensionsGlyphSize": 27,
        "omnibarFieldTrailingGap": 4.5, "omnibarFontSize": 13.753, "omnibarHeight": 28, "omnibarIconLeading": 2,
        "omnibarIconSize": 17, "omnibarIconViewSize": 22.5, "omnibarLineBoxBaseline": 1, "omnibarMoreGlyphSize": 20,
        "omnibarPopupBottomPadding": 3.5, "omnibarPopupCornerRadius": 11, "omnibarPopupRowCornerRadius": 7,
        "omnibarPopupRowGap": 2, "omnibarPopupSideOutset": 6.5, "omnibarPopupTopOutset": 2.5, "omnibarStarGlyphSize": 23.5,
        "omnibarTextGap": 4.5, "omnibarTrailingIconSize": 16, "omnibarTrailingPadding": 7, "rowCornerRadius": 8,
        "sidebarContentInset": 6.5, "sidebarIconColumn": 15, "sidebarIconGap": 6.5, "sidebarLineBoxBaseline": 1,
        "sidebarRowHeight": 24, "sidebarRowInset": 5.5, "sidebarTitleSize": 12.6, "tabCornerRadius": 8, "tabGap": 2.5,
        "tabIconSize": 15, "tabIconTitleGap": 6.5, "tabMaxWidth": 181, "tabStripHeight": 33, "tabTitleSize": 12.6,
        "toolbarGlyphSize": 22.5,
    ]

    @Test func compactIsTheUsersTunedDensity() {
        let compact = DensityPreset.compact.tokens
        for (key, value) in Self.tuned.sorted(by: { $0.key < $1.key }) {
            #expect(compact.tokens[key].map { abs($0 - value) < 0.0005 } == true, "Compact's \(key) is \(String(describing: compact.tokens[key])), the user's \(value)")
        }
        #expect(Set(compact.tokens.keys) == Set(Self.tuned.keys), "Compact sets \(Set(compact.tokens.keys).symmetricDifference(Self.tuned.keys).sorted()) beyond or short of the user's list")
        #expect(abs(compact.level - 0.15) < 0.0005, "Compact's level is \(compact.level)")
        #expect(abs(compact.spacing - 0.9) < 0.0005, "Compact's spacing is \(compact.spacing)")
        #expect(compact.fontSize.map { abs($0 - 12.6) < 0.0005 } == true, "Compact's body size is \(String(describing: compact.fontSize))")
    }

    /// The tuned Compact changes only Compact: the other built-ins keep Default's proportions.
    @Test(arguments: [DensityPreset.ultraCompact, .comfortable, .spacious])
    func theOtherDensitiesKeepTheirGap(density: DensityPreset) {
        let reference = 3 * density.scaleFactor
        let gap = density.tokens.tokens["browserRowGap"] ?? -1
        #expect(abs(gap - (reference * 2).rounded() / 2) < 0.0005, "\(density)'s strip padding is \(gap)")
    }
}
