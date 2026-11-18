public import AppKit

extension Glass {
    /// The overlay role whose glass a web page's floating surface draws on (webviews
    /// ui/glass/hostGlass.ts levels): popovers and menus their own, chips a tooltip's. Docked glass
    /// (`chrome`) is the window's own and draws a popover if asked.
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
    public nonisolated static func hostTintLevel(_ level: GlassLevel) -> GlassLevel {
        level == .chrome ? .popover : level
    }
}
