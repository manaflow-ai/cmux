extension SurfaceRole {
    /// The glass level the role's surface is (``GlassLevel``; design/glass.md): popovers, toasts and
    /// sheets float over content, menus are the menu level, tooltips the chip, and the sidebar's
    /// cards and group headers sit on the window's chrome.
    public nonisolated var glassLevel: GlassLevel {
        switch self {
        case .popover, .toast, .sheet: .popover
        case .menu: .menu
        case .tooltip: .chip
        case .card, .group: .chrome
        }
    }
}
