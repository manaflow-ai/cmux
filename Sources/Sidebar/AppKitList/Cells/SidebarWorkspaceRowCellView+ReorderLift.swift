import AppKit

/// Reorder lift support: the lift moves the row's fill apart from its content.
extension SidebarWorkspaceRowTableCellView {
    /// The row's fill (selection/hover) as a standalone copy in `view`'s
    /// coordinates, for the reorder lift, which moves it apart from the
    /// content. Nil when the row has no visible fill.
    func makeLiftFillLayer(in view: NSView) -> CALayer? {
        guard let source = backgroundView.layer, !backgroundView.isHidden,
              (source.backgroundColor?.alpha ?? 0) > 0 || source.borderWidth > 0 else { return nil }
        let fill = CALayer()
        let frame = backgroundView.convert(backgroundView.bounds, to: view)
        fill.frame = CGRect(x: frame.minX, y: 0, width: frame.width, height: view.bounds.height)
        fill.backgroundColor = source.backgroundColor
        fill.cornerRadius = source.cornerRadius
        fill.cornerCurve = source.cornerCurve
        fill.borderWidth = source.borderWidth
        fill.borderColor = source.borderColor
        // The stock light pill's glass lives on the wash layer; carry it.
        if SidebarGlassSelection.wearsLightPill(source, for: model?.colorSchemeIsDark == true ? .dark : .light) {
            let glass = CAGradientLayer()
            fill.addSublayer(glass)
            SidebarGlassSelection.paintSelectionGlass(glass)
            SidebarGlassSelection.fitOverlay(glass)
            glass.cornerCurve = source.cornerCurve
        }
        return fill
    }

    /// Hides the fill so the lift can snapshot the content alone.
    func setLiftFillHidden(_ hidden: Bool) {
        backgroundView.isHidden = hidden
    }
}
