import CMUXMobileCore

/// Lightweight text styling retained by a terminal preview snapshot.
public struct PreviewGridStyle: Equatable, Sendable {
    /// Whether the text uses a bold face.
    public let isBold: Bool
    /// Whether the text is visually de-emphasized.
    public let isDim: Bool
    /// Whether the text is hidden by the terminal style.
    public let isInvisible: Bool

    init(renderGridStyle: MobileTerminalRenderGridFrame.Style) {
        isBold = renderGridStyle.bold
        isDim = renderGridStyle.faint
        isInvisible = renderGridStyle.invisible
    }
}
