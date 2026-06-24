public import SwiftUI

/// A snapshot of the app-side Feed Button Style debug settings, injected into a
/// ``FeedButton`` so the `#if DEBUG` style-exploration path can override the
/// button's treatment without the package depending on the app's
/// `@AppStorage`/`UserDefaults` repository.
///
/// All settings *reads* stay app-side: the app constructs this value from its
/// `FeedButtonDebugSettings` repository, resolving the per-kind color overrides
/// up front (it already knows the button's `kind` and `colorScheme`), and hands
/// the package only the resolved numbers and a role-keyed color lookup. When a
/// ``FeedButton`` is given no debug style (production, or the `#if !DEBUG`
/// build), it renders the byte-faithful production `solid` treatment.
///
/// The type stores a closure (`color`) and is therefore not `Sendable`; it is
/// constructed and consumed entirely on the main actor inside the SwiftUI view
/// body, never crossing an isolation boundary.
public struct FeedButtonDebugStyle {
    /// The visual treatment to render.
    public let visualStyle: FeedButtonVisualStyle
    /// Corner radius for compact-size buttons.
    public let compactCornerRadius: CGFloat
    /// Corner radius for medium-size buttons.
    public let mediumCornerRadius: CGFloat
    /// Horizontal content padding for compact-size buttons.
    public let compactHorizontalPadding: CGFloat
    /// Horizontal content padding for medium-size buttons.
    public let mediumHorizontalPadding: CGFloat
    /// Vertical content padding for compact-size buttons.
    public let compactVerticalPadding: CGFloat
    /// Vertical content padding for medium-size buttons.
    public let mediumVerticalPadding: CGFloat
    /// Opacity applied to the kind tint over a glass material.
    public let glassTintOpacity: Double
    /// Stroke width for treatments that draw a border.
    public let borderWidth: CGFloat

    /// Resolves the override color for a role, already bound by the app to the
    /// button's `kind` and `colorScheme`. Returns `nil` to fall back to the
    /// built-in per-kind color.
    public let color: (FeedButtonColorRole) -> Color?

    /// Creates a debug-style snapshot.
    /// - Parameters:
    ///   - visualStyle: The visual treatment to render.
    ///   - compactCornerRadius: Corner radius for compact-size buttons.
    ///   - mediumCornerRadius: Corner radius for medium-size buttons.
    ///   - compactHorizontalPadding: Horizontal padding for compact-size buttons.
    ///   - mediumHorizontalPadding: Horizontal padding for medium-size buttons.
    ///   - compactVerticalPadding: Vertical padding for compact-size buttons.
    ///   - mediumVerticalPadding: Vertical padding for medium-size buttons.
    ///   - glassTintOpacity: Opacity of the kind tint over glass.
    ///   - borderWidth: Stroke width for bordered treatments.
    ///   - color: Role-keyed override-color lookup, pre-bound to kind/colorScheme.
    public init(
        visualStyle: FeedButtonVisualStyle,
        compactCornerRadius: CGFloat,
        mediumCornerRadius: CGFloat,
        compactHorizontalPadding: CGFloat,
        mediumHorizontalPadding: CGFloat,
        compactVerticalPadding: CGFloat,
        mediumVerticalPadding: CGFloat,
        glassTintOpacity: Double,
        borderWidth: CGFloat,
        color: @escaping (FeedButtonColorRole) -> Color?
    ) {
        self.visualStyle = visualStyle
        self.compactCornerRadius = compactCornerRadius
        self.mediumCornerRadius = mediumCornerRadius
        self.compactHorizontalPadding = compactHorizontalPadding
        self.mediumHorizontalPadding = mediumHorizontalPadding
        self.compactVerticalPadding = compactVerticalPadding
        self.mediumVerticalPadding = mediumVerticalPadding
        self.glassTintOpacity = glassTintOpacity
        self.borderWidth = borderWidth
        self.color = color
    }
}
