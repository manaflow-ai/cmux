public import AppKit

/// Fonts and metrics of the question card at one text scale. Colors come
/// from the theme at draw time (`AgentQuestionCardView.applyColors`); these
/// values are pure, so measuring and drawing agree.
public struct AgentQuestionCardStyle: Equatable, Sendable {
    /// 1 is the default text size; the gallery and Dynamic sizes pass 1.15, 1.3.
    public var scale: CGFloat

    public init(scale: CGFloat = 1) {
        self.scale = scale
    }

    func size(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }

    var padding: CGFloat { size(14) }
    var cornerRadius: CGFloat { size(16) }
    var gap: CGFloat { size(10) }
    var rowGap: CGFloat { size(2) }
    var rowInset: CGFloat { size(8) }
    var rowMinHeight: CGFloat { size(34) }
    var keycapSize: CGFloat { size(20) }
    var chipHeight: CGFloat { size(20) }
    var chipInset: CGFloat { size(8) }
    var buttonHeight: CGFloat { size(26) }
    var buttonInset: CGFloat { size(12) }
    var checkSize: CGFloat { size(14) }
    /// The preview pane sits beside the options at this card width or more.
    var sideBySideMinWidth: CGFloat { size(520) }
    var previewMinHeight: CGFloat { size(96) }
    var previewInset: CGFloat { size(10) }

    var chipFont: NSFont { .systemFont(ofSize: size(11), weight: .semibold) }
    var metaFont: NSFont { .systemFont(ofSize: size(11), weight: .regular) }
    var promptFont: NSFont { .systemFont(ofSize: size(14), weight: .semibold) }
    var labelFont: NSFont { .systemFont(ofSize: size(13), weight: .medium) }
    var detailFont: NSFont { .systemFont(ofSize: size(12), weight: .regular) }
    var keycapFont: NSFont { .monospacedSystemFont(ofSize: size(11), weight: .medium) }
    var previewFont: NSFont { .monospacedSystemFont(ofSize: size(11), weight: .regular) }
    var buttonFont: NSFont { .systemFont(ofSize: size(12), weight: .semibold) }
    var summaryFont: NSFont { .systemFont(ofSize: size(13), weight: .regular) }
}
