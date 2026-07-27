public import AppKit

/// Immutable description of one appearance-resolved icon render pass.
@MainActor
public struct CmuxResolvedIconRequest {
    /// The source image to resolve and draw.
    public let source: CmuxResolvedIconSource
    /// Final icon size in points.
    public let size: NSSize
    /// Optional explicit tint. When set, the source alpha is used as the mask.
    public let tintColor: NSColor?
    /// SF Symbol weight used only for ``CmuxResolvedIconSource/systemSymbol(name:accessibilityDescription:)``.
    public let symbolWeight: NSFont.Weight
    /// Optional accessibility label for the rendered image view.
    public let accessibilityDescription: String?

    /// Creates an icon render request.
    /// - Parameters:
    ///   - source: Source image to resolve.
    ///   - size: Final icon size in points.
    ///   - tintColor: Optional tint applied while drawing under the effective appearance.
    ///   - symbolWeight: SF Symbol weight for symbol sources.
    ///   - accessibilityDescription: Optional accessibility label for image views.
    public init(
        source: CmuxResolvedIconSource,
        size: NSSize,
        tintColor: NSColor? = nil,
        symbolWeight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) {
        self.source = source
        self.size = size
        self.tintColor = tintColor
        self.symbolWeight = symbolWeight
        self.accessibilityDescription = accessibilityDescription
    }
}
