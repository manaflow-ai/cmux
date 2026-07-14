import CMUXMobileCore

/// Lightweight text styling retained by a terminal preview snapshot.
public struct PreviewGridStyle: Equatable, Sendable {
    /// Whether the text uses a bold face.
    public let isBold: Bool
    /// Whether the text is visually de-emphasized.
    public let isDim: Bool
    /// Whether the text is hidden by the terminal style.
    public let isInvisible: Bool

    /// Creates one lightweight renderer style.
    public init(isBold: Bool = false, isDim: Bool = false, isInvisible: Bool = false) {
        self.isBold = isBold
        self.isDim = isDim
        self.isInvisible = isInvisible
    }

    init(renderGridStyle: MobileTerminalRenderGridFrame.Style) {
        isBold = renderGridStyle.bold
        isDim = renderGridStyle.faint
        isInvisible = renderGridStyle.invisible
    }
}
