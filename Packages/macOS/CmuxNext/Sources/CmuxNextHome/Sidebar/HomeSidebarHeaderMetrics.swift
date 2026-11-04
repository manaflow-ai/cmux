import CmuxNextDesign
import CoreGraphics

/// The Home list header's sizes under the sidebar's `sidebar.density` and `sidebar.textSize`.
/// Stub: every density and text size gives the Compact, default-text sizes.
struct HomeSidebarHeaderMetrics: Equatable, Sendable {
    var side: CGFloat
    var chipHeight: CGFloat
    var chipGap: CGFloat
    var chipPadding: CGFloat
    var chipFontSize: CGFloat
    var chipGlyphSize: CGFloat
    var emptyTextStep: CGFloat

    static let standard = HomeSidebarHeaderMetrics(side: 30, chipHeight: 24, chipGap: 6, chipPadding: 10,
                                                   chipFontSize: TypeScale.Base.detail,
                                                   chipGlyphSize: (TypeScale.Base.caption * 0.8).rounded(), emptyTextStep: 0)

    private init(side: CGFloat, chipHeight: CGFloat, chipGap: CGFloat, chipPadding: CGFloat,
                 chipFontSize: CGFloat, chipGlyphSize: CGFloat, emptyTextStep: CGFloat) {
        self.side = side
        self.chipHeight = chipHeight
        self.chipGap = chipGap
        self.chipPadding = chipPadding
        self.chipFontSize = chipFontSize
        self.chipGlyphSize = chipGlyphSize
        self.emptyTextStep = emptyTextStep
    }

    init(tokens: SidebarRowTokens, detail: CGFloat, caption: CGFloat) {
        self = .standard
    }
}
