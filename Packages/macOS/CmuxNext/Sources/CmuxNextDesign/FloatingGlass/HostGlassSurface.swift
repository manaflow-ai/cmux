public import AppKit

extension Glass {
    /// The overlay role whose glass a web page's floating surface draws on (webviews
    /// ui/glass/hostGlass.ts levels): popovers and menus their own, chips a tooltip's. Docked glass
    /// (`chrome`) is a popover's glass at the chrome level's tint (``makeHostSurface(level:role:)``).
    public nonisolated static func hostGlassRole(_ level: GlassLevel) -> SurfaceRole {
        switch level {
        case .menu: .menu
        case .chip: .tooltip
        case .chrome, .popover: .popover
        }
    }

    /// The tint density the App's glass under a web surface of `level` takes (host glass: the agent
    /// pane's page, the Liquid Glass Parity playground): the level's own, so a web menu's glass is a native
    /// menu's (``makeMenuPanel(content:cornerRadius:interactive:)`` sets ``GlassMenuMaterial/level``) and
    /// the page lays only the veil (`--host-glass-fill`) on it. Before, every host surface took the
    /// popover density, so a web menu beside a native one was a lighter glass.
    /// The roles a web surface may ask for by name instead of its level's (`data-host-glass-role`,
    /// hostGlass.ts `HostGlassRole`): a dialog's neutral glass, as a native dialog card draws it
    /// (CmuxDialogCardSurface, `.sheet`), and a toast's.
    public nonisolated static let hostGlassRoles: [String: SurfaceRole] = ["sheet": .sheet, "toast": .toast]

    public nonisolated static func hostTintLevel(_ level: GlassLevel) -> GlassLevel { level }

    /// The App's whole native surface under a web surface of `level` (host glass: the agent pane's page,
    /// the Liquid Glass Parity playground), or of the role it names (`data-host-glass-role`): the surface
    /// the App's own UI draws for it, veil and rim included, so the page lays only its content on it and
    /// the two match by construction. A menu is the native menu panel (its veil, ``makeMenuPanel(content:cornerRadius:interactive:)``),
    /// a popover or hover card the one transient material of the native popovers (the palette, page
    /// info: ``FloatingGlassStyle/transient``), a chip the tooltip's whole surface (its legibility tint
    /// and shadow, ``makeTooltipGlass(cornerRadius:interactive:)``), docked glass (`chrome`: the tab
    /// strip's, a drag ghost's) the theme's glass at the chrome level's tint, a named role its own.
    @MainActor
    public static func makeHostSurface(level: GlassLevel, role: SurfaceRole? = nil) -> OverlaySurfaceView {
        if let role {
            let view = makeSurface(role, interactive: false)
            view.tintLevel = hostTintLevel(level)
            return view
        }
        switch level {
        case .menu:
            return makeMenuPanel(interactive: false)
        case .chip:
            return makeTooltipGlass(interactive: false)
        case .chrome:
            let view = makeOverlayPanel(interactive: false)
            view.tintLevel = .chrome
            return view
        case .popover:
            return makeOverlayPanel(interactive: false, tone: .neutralGlass(.transient))
        }
    }
}
