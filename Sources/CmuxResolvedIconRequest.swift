import AppKit

/// Immutable inputs for one appearance-resolved icon render pass.
@MainActor
struct CmuxResolvedIconRequest {
    /// Candidate sources, tried in order until one produces visible pixels.
    let sources: [CmuxResolvedIconSource]
    /// Output size in points.
    let size: NSSize
    /// Optional tint applied to the source alpha mask while drawing.
    let tintColor: NSColor?
    /// SF Symbol weight used by system-symbol candidates.
    let symbolWeight: NSFont.Weight
    /// Optional accessibility description for the host image view.
    let accessibilityDescription: String?

    /// Creates a request with one primary source.
    init(
        source: CmuxResolvedIconSource,
        size: NSSize,
        tintColor: NSColor? = nil,
        symbolWeight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) {
        self.init(
            sources: [source],
            size: size,
            tintColor: tintColor,
            symbolWeight: symbolWeight,
            accessibilityDescription: accessibilityDescription
        )
    }

    /// Creates a request with ordered fallbacks.
    init(
        sources: [CmuxResolvedIconSource],
        size: NSSize,
        tintColor: NSColor? = nil,
        symbolWeight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) {
        self.sources = sources
        self.size = size
        self.tintColor = tintColor
        self.symbolWeight = symbolWeight
        self.accessibilityDescription = accessibilityDescription
    }
}
