public import AppKit

/// Resolved background painting decision for one terminal surface.
public struct TerminalSurfaceBackgroundFillPlan {
    /// The layer or renderer that owns the visible terminal background.
    public let owner: TerminalSurfaceBackgroundFillOwner

    /// Color to apply to the terminal host layer, or clear when another layer owns the fill.
    public let hostLayerColor: NSColor

    /// Whether a host-layer fill must subtract itself from the shared window backdrop.
    public let clearsSharedWindowBackdrop: Bool

    /// Creates a terminal surface background fill plan.
    public init(
        owner: TerminalSurfaceBackgroundFillOwner,
        hostLayerColor: NSColor,
        clearsSharedWindowBackdrop: Bool
    ) {
        self.owner = owner
        self.hostLayerColor = hostLayerColor
        self.clearsSharedWindowBackdrop = clearsSharedWindowBackdrop
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
        let resolvedColor = (surfaceBackgroundColor ?? defaultBackgroundColor)
            .withAlphaComponent(WindowAppearanceSnapshot.clampedOpacity(backgroundOpacity))
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
        return Self(
            owner: owner,
            hostLayerColor: owner == .surfaceHostLayer ? resolvedColor : .clear,
            clearsSharedWindowBackdrop: usesPaneLocalSurfaceFill && sharesWindowBackdrop
        )
    }
}
