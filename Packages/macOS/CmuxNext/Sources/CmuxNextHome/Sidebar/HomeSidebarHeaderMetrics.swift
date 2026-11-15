import CmuxNextDesign
import CoreGraphics

/// The Home list header's sizes under the sidebar's `sidebar.density` and `sidebar.textSize` (the
/// user, 2026-11-04: the Sidebar States Playground's Home filter columns all looked the same). At
/// Compact with the default text they are ``standard``, the header's sizes before (a 30 pt filter
/// circle and search field, a 24 pt Unread chip); a bigger density or text size adds the band
/// tokens' extra height (``SidebarRowTokens/band``, so Expanded is Comfortable's, as the pinned rows
/// above the list; ``SidebarRowTokens/extraHeight``) to the circle and the chip, and the text
/// step (`SidebarTextSize.textStep`) to their text. Pure: ``HomeSidebarHeaderLayout`` and the views
/// take one through their initializers; ``current`` reads the app's settings.
nonisolated struct HomeSidebarHeaderMetrics: Equatable, Sendable {
    /// The filter circle's diameter and the search capsule's height, as in Messages (its glass
    /// filter and search field are one height).
    var side: CGFloat
    /// The on filter's chip height, and the gap under it to the list.
    var chipHeight: CGFloat
    var chipGap: CGFloat
    /// The chip's side padding around its text and xmark.
    var chipPadding: CGFloat
    /// The chip's text size and its xmark's point size.
    var chipFontSize: CGFloat
    var chipGlyphSize: CGFloat
    /// Points added to the empty list's No Unread Chats and Show All text.
    var emptyTextStep: CGFloat

    /// Compact with the default text at Interface Size 100 %.
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

    /// - Parameters:
    ///   - tokens: The sidebar's row tokens (its density, its text size and the app's base tokens);
    ///     the header reads their ``SidebarRowTokens/band``.
    ///   - detail: The detail text size (`TypeScale.detail`): the chip's text at the default text size.
    ///   - caption: The caption text size (`TypeScale.caption`): the xmark is 80 % of it.
    init(tokens: SidebarRowTokens, detail: CGFloat, caption: CGFloat) {
        let base = Self.standard
        let tokens = tokens.band
        let extra = tokens.extraHeight
        let step = tokens.textSize.textStep
        self.init(side: base.side + extra, chipHeight: base.chipHeight + extra,
                  chipGap: base.chipGap + (extra / 2).rounded(), chipPadding: base.chipPadding + (extra / 2).rounded(),
                  chipFontSize: detail + step, chipGlyphSize: (caption * 0.8).rounded() + step, emptyTextStep: step)
    }

    /// The header at the app's sidebar settings now.
    @MainActor static var current: HomeSidebarHeaderMetrics {
        HomeSidebarHeaderMetrics(tokens: SidebarRowTokens.current, detail: TypeScale.detail, caption: TypeScale.caption)
    }
}
