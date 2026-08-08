public import AppKit

/// Resolved background painting decision for one terminal surface.
public struct TerminalSurfaceBackgroundFillPlan {
    /// The layer or renderer that owns the visible terminal background.
    public let owner: TerminalSurfaceBackgroundFillOwner

    /// Color to apply to the terminal host layer, or clear when another layer owns the fill.
    public let hostLayerColor: NSColor

    /// Whether this pane's host fill must exclude the shared root below it.
    public let excludesSharedRootBackdrop: Bool

    /// Creates a terminal surface background fill plan.
    ///
    /// - Parameters:
    ///   - owner: Component responsible for the visible terminal background.
    ///   - hostLayerColor: Color painted by the terminal host, or clear for another owner.
    ///   - excludesSharedRootBackdrop: Whether the shared root must leave this pane clear.
    public init(
        owner: TerminalSurfaceBackgroundFillOwner,
        hostLayerColor: NSColor,
        excludesSharedRootBackdrop: Bool
    ) {
        self.owner = owner
        self.hostLayerColor = hostLayerColor
        self.excludesSharedRootBackdrop = excludesSharedRootBackdrop
    }

    /// Whether the terminal host layer should paint a non-clear fill.
    public var usesHostLayerFill: Bool {
        owner == .surfaceHostLayer
    }

    /// Compact debug label for the selected backdrop owner.
    public var logBackdropLabel: String {
        switch owner {
        case .surfaceHostLayer:
            return "terminal"
        case .sharedWindowBackdrop:
            return "shared"
        case .bonsplitPaneBackdrop:
            return "bonsplit-pane"
        case .ghosttyNativeRenderer:
            return "ghostty-native"
        }
    }

    /// Returns the debug-log source label for the selected owner.
    public func logSource(hasSurfaceOverride: Bool) -> String {
        switch owner {
        case .surfaceHostLayer:
            return hasSurfaceOverride ? "surfaceOverride" : "defaultBackground"
        case .sharedWindowBackdrop:
            return "sharedWindowBackdrop"
        case .bonsplitPaneBackdrop:
            return "bonsplitPaneBackdrop"
        case .ghosttyNativeRenderer:
            return "ghosttyNativeBackground"
        }
    }

    /// Computes the terminal background owner and host-layer color for current appearance state.
    public static func resolve(
        renderingMode: GhosttyTerminalBackdropRenderingMode,
        surfaceBackgroundColor: NSColor?,
        defaultBackgroundColor: NSColor,
        backgroundOpacity: Double,
        sharesWindowBackdrop: Bool,
        usesBonsplitPaneBackdrop: Bool
    ) -> Self {
        let backgroundColor = surfaceBackgroundColor ?? defaultBackgroundColor
        let opacity = WindowAppearanceSnapshot.clampedOpacity(backgroundOpacity)
        let translucentColor = backgroundColor.withAlphaComponent(opacity)
        let owner: TerminalSurfaceBackgroundFillOwner
        let usesPaneLocalSurfaceFill = surfaceBackgroundColor != nil &&
            renderingMode.usesWindowHostBackdrop &&
            !usesBonsplitPaneBackdrop
        if !renderingMode.usesWindowHostBackdrop {
            owner = .ghosttyNativeRenderer
        } else if usesPaneLocalSurfaceFill {
            owner = .surfaceHostLayer
        } else if !sharesWindowBackdrop && !usesBonsplitPaneBackdrop {
            owner = .surfaceHostLayer
        } else if sharesWindowBackdrop {
            owner = .sharedWindowBackdrop
        } else {
            owner = .bonsplitPaneBackdrop
        }

        let hostLayerColor: NSColor
        if owner != .surfaceHostLayer {
            hostLayerColor = .clear
        } else if opacity >= 0.999 {
            hostLayerColor = WindowAppearanceSnapshot.compositedTerminalColor(
                backgroundColor: backgroundColor,
                opacity: Double(opacity)
            )
        } else {
            hostLayerColor = translucentColor
        }
        return Self(
            owner: owner,
            hostLayerColor: hostLayerColor,
            excludesSharedRootBackdrop: usesPaneLocalSurfaceFill &&
                sharesWindowBackdrop &&
                opacity < 0.999
        )
    }
}
