/// How the surfaces' config differs from the user's: in a translucent
/// window the surfaces draw a transparent default background, so the window
/// root's sheet (`background` at `background-opacity`) is the only layer
/// behind the cells, as the single surface layer is in Ghostty.app. With
/// `background-opacity-cells` explicit cell colors take the opacity, and a
/// 0 would erase them, so the config stays as it is. A terminal background
/// override (`appearance.surfaces.terminal`) makes the surfaces transparent
/// in an opaque window too: the terminal host paints the override behind
/// the cells (`ownerPaintsBackground`). So does background art, which makes
/// a window see-through at full opacity: the host then paints only where the
/// panes do (`WindowBackdrop.panesPaintBackground`), and the art reads
/// through the window's one legible tint behind the cells.
nonisolated enum GhosttyRuntimeSurfacePolicy {
    static func override(configuredOpacity: Double, opacityCells: Bool, ownerPaintsBackground: Bool = false) -> String? {
        (configuredOpacity < 1 || ownerPaintsBackground) && !opacityCells ? "background-opacity = 0" : nil
    }
}
