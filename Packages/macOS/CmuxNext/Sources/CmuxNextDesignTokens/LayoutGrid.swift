public import CoreGraphics

/// The shared layout grid in unscaled points. The CSS copy follows interface scale.
/// Hand-maintained against schemas/layout-grid/layout-grid.json by gen-layout-grid.py --check.
/// Menus use MenuMetrics. Comfortable icon boxes apply only to sidebar and Home lists.
public nonisolated struct LayoutGrid: Sendable {
    public init() {}

    public static let base: CGFloat = 4
    public static let halfStep: CGFloat = 2
    public static let iconBox: CGFloat = 16
    public static let iconBoxComfortable: CGFloat = 20
    public static let glyph: CGFloat = 12
    public static let gap: CGFloat = 8
    public static let row: CGFloat = 28
    public static let rowComfortable: CGFloat = 32
    public static let pillInset: CGFloat = 2
    public static let pill: CGFloat = 24
    public static let pillComfortable: CGFloat = 28
    public static let composerInset: CGFloat = 8
    public static let composerControl: CGFloat = 28
    public static let composerLeadCenter: CGFloat = 22
    public static let composerText: CGFloat = 44
    public static let composerTrailCenter: CGFloat = 22
    public static let stripInset: CGFloat = 8
    public static let stripControl: CGFloat = 28
    public static let stripLeadCenter: CGFloat = 22
    public static let stripText: CGFloat = 44
    public static let stripTrailCenter: CGFloat = 22
    public static let trustBarInset: CGFloat = 8
    public static let trustBarControl: CGFloat = 28
    public static let trustBarLeadCenter: CGFloat = 22
    public static let trustBarText: CGFloat = 44
    public static let trustBarTrailCenter: CGFloat = 22
    public static let trayInset: CGFloat = 8
    public static let trayControl: CGFloat = 28
    public static let trayLeadCenter: CGFloat = 22
    public static let trayText: CGFloat = 44
    public static let trayTrailCenter: CGFloat = 22
    public static let queueInset: CGFloat = 8
    public static let queueControl: CGFloat = 28
    public static let queueLeadCenter: CGFloat = 22
    public static let queueText: CGFloat = 44
    public static let queueTrailCenter: CGFloat = 22
    public static let composerBlockInset: CGFloat = 10
    public static let composerBox: CGFloat = 48
    public static let composerRadius: CGFloat = 12
    public static let composerQuietRowGap: CGFloat = 4
    public static let composerQuietRowHeight: CGFloat = 28
    public static let composerQuietRowText: CGFloat = 14
    public static let sidebarHighlightInset: CGFloat = 8
    public static let sidebarLead: CGFloat = 16
    public static let sidebarText: CGFloat = 40
    public static let sidebarTextComfortable: CGFloat = 44
    public static let sidebarDepthIndent: CGFloat = 16
    public static let sidebarTrailCenter: CGFloat = 24
    public static let sidebarTrailCenterComfortable: CGFloat = 24
    public static let sidebarSecondMarkPitch: CGFloat = 20
    public static let sidebarSecondMarkPitchComfortable: CGFloat = 20
    public static let transcriptIconBox: CGFloat = 16
    public static let transcriptTextGap: CGFloat = 24
    public static let gapBlock: CGFloat = 24
    public static let gapTurn: CGFloat = 32
    public static let gapInner: CGFloat = 12
    public static let gapComposer: CGFloat = 16
    public static let gapFoot: CGFloat = 4
    public static let transcriptActionControl: CGFloat = 28
    public static let transcriptActionTrailCenter: CGFloat = 14
    public static let transcriptFooterControl: CGFloat = 32
    public static let transcriptFooterIcon: CGFloat = 20
    public static let gapFooter: CGFloat = 8
    public static let cardsPadding: CGFloat = 12
    public static let cardsLead: CGFloat = 12
    public static let cardsText: CGFloat = 36
    public static let cardsControl: CGFloat = 28
    public static let cardsTrailCenter: CGFloat = 26
    public static let cardsRadius: CGFloat = 12
}
