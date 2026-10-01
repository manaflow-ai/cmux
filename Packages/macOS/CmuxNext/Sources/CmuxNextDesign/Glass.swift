public import AppKit

/// Liquid Glass helpers wrapping `NSGlassEffectView`.
///
/// Use glass for chrome only (sidebar, tab strip, palette, popovers), never
/// over terminal content. When several glass panels sit near each other,
/// wrap them in `makeContainer` so AppKit merges and batches their rendering.
public struct Glass {
    public init() {}
    public enum Style: Sendable {
        case regular
        case clear
    }

    /// A glass panel that hosts `content` edge to edge.
    public static func makePanel(
        content: NSView? = nil,
        style: Style = .regular,
        cornerRadius: CGFloat = Metrics.panelCornerRadius,
        interactive: Bool = false
    ) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = cornerRadius
        glass.tintColor = Palette.glassTint
        switch style {
        case .regular: glass.style = .regular
        case .clear: glass.style = .clear
        }
        setInteractive(glass, interactive)
        glass.contentView = content
        return glass
    }

    /// A container that merges nearby glass panels and batches rendering.
    public static func makeContainer(content: NSView, spacing: CGFloat = 0) -> NSGlassEffectContainerView {
        let container = NSGlassEffectContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.spacing = spacing
        container.contentView = content
        return container
    }

    /// `effectIsInteractive` is macOS 27 SDK only. Xcode 26.x (CI and fleet)
    /// lacks the symbol even inside `#available`, so it also needs a compiler
    /// guard (plans/cmux-next/shell.md section 3.3).
    private static func setInteractive(_ glass: NSGlassEffectView, _ interactive: Bool) {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = interactive
        }
        #endif
    }
}
