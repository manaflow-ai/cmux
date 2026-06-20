#if canImport(AppKit)

public import AppKit
public import Bonsplit

/// The app-target reads the ``TabBarBackdropLabView`` samples, captured as one
/// value at the moment the app builds the panel content.
///
/// The lab renders live `Bonsplit` tab bars and previews the production
/// split-button backdrop tuning against the running terminal's default
/// background. Those source values live in the app target (`GhosttyApp`'s default
/// background color/opacity and `Workspace`'s production backdrop config), so the
/// composition root snapshots them and injects this value through
/// ``DebugWindowsCoordinator``'s `tabBarBackdropLabContentProvider`. The package
/// view holds no reference to those app-target types.
///
/// The snapshot is read once, on the main actor, exactly when the panel is
/// (re)created, so it matches the timing of the former in-view `GhosttyApp.shared`
/// reads byte-for-byte.
public struct TabBarBackdropLabInputs {
    /// The terminal's configured default background opacity
    /// (`GhosttyApp.defaultBackgroundOpacity`). Seeds the initial surface-opacity
    /// slider after ``WindowAppearanceSnapshot/clampedOpacity(_:)`` clamping.
    public var defaultBackgroundOpacity: Double

    /// The terminal's default background color (`GhosttyApp.defaultBackgroundColor`),
    /// already resolved to a concrete `NSColor`. Drives the sample terminal fill.
    public var defaultBackgroundColor: NSColor

    /// The production split-button backdrop softness
    /// (`Workspace.bonsplitSplitButtonBackdropSoftness`). Seeds the candidate-softness
    /// slider and anchors the candidate-effect interpolation.
    public var productionBackdropSoftness: CGFloat

    /// The production split-button backdrop effect
    /// (`Workspace.bonsplitSplitButtonBackdropEffect()`). The candidate variant
    /// interpolates between hardcoded strong/soft endpoints and this production value.
    public var productionBackdropEffect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect

    /// The shared chrome bar height the running tab bars use
    /// (`WindowChromeMetrics.bonsplitTabBarHeight`). Sizes the sample `Bonsplit`
    /// appearance so the lab matches production proportions.
    public var tabBarHeight: CGFloat

    /// Creates a snapshot of the app-target backdrop tuning the lab previews.
    public init(
        defaultBackgroundOpacity: Double,
        defaultBackgroundColor: NSColor,
        productionBackdropSoftness: CGFloat,
        productionBackdropEffect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect,
        tabBarHeight: CGFloat
    ) {
        self.defaultBackgroundOpacity = defaultBackgroundOpacity
        self.defaultBackgroundColor = defaultBackgroundColor
        self.productionBackdropSoftness = productionBackdropSoftness
        self.productionBackdropEffect = productionBackdropEffect
        self.tabBarHeight = tabBarHeight
    }
}

#endif
