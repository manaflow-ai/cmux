extension LayoutRootView {
    /// Equalize Splits on screen `id` (``LayoutModel/equalize(screen:viewportWidth:)``), at the width the screen shows:
    /// a dock's width is a share of that width, so it equalizes only while the screen has one.
    @discardableResult
    public func equalize(screen id: ScreenID) -> LayoutModel.EqualizeResult {
        let geometry = screenViews[id]?.baseGeometry
        let width = geometry.map(\.viewport.width).flatMap { $0 > 0 ? $0 : nil }
        return model.equalize(screen: id, viewportWidth: width, geometry: geometry)
    }
}
