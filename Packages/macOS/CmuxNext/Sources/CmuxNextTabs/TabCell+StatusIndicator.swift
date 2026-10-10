import CmuxNextDesign

/// The tab's busy indicator: the shared `StatusIndicatorLayer` in the icon
/// slot. A busy cell registers with `StatusIndicatorAppearance`, so a
/// settings or Debug Settings change restyles it live; idle cells cost
/// nothing.
extension TabCell: StatusIndicatorConfigClient {
    /// The plan the tab's indicator draws now (hidden when not busy or the
    /// style is `none`).
    var spinnerPlan: StatusIndicatorPlan {
        guard item.indicator.replacesTabIcon else { return .hidden }
        let config = StatusIndicatorAppearance.shared.config
        return StatusIndicatorPlan.make(item.indicator, style: config.style(hint: item.busyStyle), animates: config.animatesLoops, set: config.iconSet)
    }

    /// Creates, updates or removes the indicator for the current item and
    /// config.
    func updateSpinner() {
        // Registered while busy even when the style draws nothing (`none`),
        // so switching the style back shows the indicator.
        if item.isBusy { StatusIndicatorAppearance.shared.register(self) }
        let plan = spinnerPlan
        if plan.glyph != .none {
            makeSpinner().apply(plan, config: StatusIndicatorAppearance.shared.config)
        } else {
            spinnerLayer?.layer.removeFromSuperlayer()
            spinnerLayer = nil
        }
        layoutLayers()
    }

    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        if item.status != .none { updateStatusGlyph() }
        guard item.isBusy else { return }
        updateSpinner()
        updateColors(animated: false)
    }
}
