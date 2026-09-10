public import AppKit

/// Immutable description of one appearance-resolved icon render pass.
@MainActor
public struct CmuxResolvedIconRequest {
    /// The source image to resolve and draw.
    public let source: CmuxResolvedIconSource
    /// Optional source used when the primary source is unavailable or draws
    /// no visible pixels during an AppKit lifecycle transition.
    public let fallbackSource: CmuxResolvedIconSource?
    /// Final icon size in points.
    public let size: NSSize
    /// Optional explicit tint. When set, the source alpha is used as the mask.
    public let tintColor: NSColor?
    /// Optional tint used only when ``fallbackSource`` is selected.
    public let fallbackTintColor: NSColor?
    /// SF Symbol weight used only for ``CmuxResolvedIconSource/systemSymbol(name:accessibilityDescription:)``.
    public let symbolWeight: NSFont.Weight
    /// Optional explicit SF Symbol configuration point size. When `nil`, the
    /// symbol is configured from the smaller ``size`` dimension.
    public let symbolPointSize: CGFloat?
    /// Optional accessibility label for the rendered image view.
    public let accessibilityDescription: String?

    /// Creates an icon render request.
    /// - Parameters:
    ///   - source: Source image to resolve.
    ///   - fallbackSource: Source to try when `source` is unavailable or blank.
    ///   - size: Final icon size in points.
    ///   - tintColor: Optional tint applied while drawing under the effective appearance.
    ///   - fallbackTintColor: Optional tint applied only to the fallback source;
    ///     when omitted, ``tintColor`` is reused.
    ///   - symbolWeight: SF Symbol weight for symbol sources.
    ///   - accessibilityDescription: Optional accessibility label for image views.
    ///   - symbolPointSize: Explicit SF Symbol point size for symbol sources.
    ///     Pass the configured symbol's natural size as ``size`` to draw the
    ///     glyph at the same scale AppKit uses for that point size.
    public init(
        source: CmuxResolvedIconSource,
        size: NSSize,
        tintColor: NSColor? = nil,
        symbolWeight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil,
        fallbackSource: CmuxResolvedIconSource? = nil,
        fallbackTintColor: NSColor? = nil,
        symbolPointSize: CGFloat? = nil
    ) {
        self.source = source
        self.fallbackSource = fallbackSource
        self.size = size
        self.tintColor = tintColor
        self.fallbackTintColor = fallbackTintColor
        self.symbolWeight = symbolWeight
        self.symbolPointSize = symbolPointSize
        self.accessibilityDescription = accessibilityDescription
    }

    /// Symbol sources with an explicit point size draw at the configured
    /// symbol's natural size instead of being scaled to fill ``size``.
    func drawsSymbolAtNaturalSize(_ source: CmuxResolvedIconSource) -> Bool {
        guard symbolPointSize != nil else { return false }
        if case .systemSymbol = source { return true }
        return false
    }
}
