import CmuxNextDesign
import QuartzCore

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
        var plan = StatusIndicatorPlan.make(item.indicator, style: config.style(hint: item.busyStyle),
                                            animates: config.animatesLoops && isWindowVisible, set: config.iconSet)
        // A page waiting for its first response turns the other way; agent work keeps `spin`.
        if item.isWaiting, item.indicator.isLoading, plan.animation == .spin { plan.animation = .spinBackward }
        return plan
    }

    /// Creates, updates or removes the indicator for the current item and
    /// config.
    func updateSpinner() {
        // Registered while busy even when the style draws nothing (`none`),
        // so switching the style back shows the indicator.
        if item.isBusy { StatusIndicatorAppearance.shared.register(self) }
        let plan = spinnerPlan
        if plan.glyph != .none {
            let spinner = makeSpinner()
            let wasHidden = spinner.layer.isHidden || spinner.plan.glyph == .none || isSpinnerExiting
            isSpinnerExiting = false
            spinner.apply(plan, config: StatusIndicatorAppearance.shared.config)
            if wasHidden {
                showSpinner(spinner, animated: item.indicator.isLoading)
            } else {
                spinner.layer.isHidden = false
            }
        } else {
            if let spinnerLayer {
                hideSpinner(spinnerLayer, animated: TabTunables.loadingAnimation.value != .instant)
            }
        }
        layoutLayers()
    }

    /// Shows a newly busy indicator without changing the tab's measured
    /// geometry. The variants are Debug Settings prototypes; `instant` is the
    /// default and preserves the old one-frame behavior.
    private func showSpinner(_ spinner: StatusIndicatorLayer, animated: Bool) {
        let variant = animated ? TabTunables.loadingAnimation.value : .instant
        let layer = spinner.layer
        layer.removeAnimation(forKey: "opacity")
        layer.removeAnimation(forKey: "transform.scale")
        layer.removeAnimation(forKey: "transform.translation.y")
        layer.isHidden = false
        guard variant != .instant, Motion.duration(.fadeIn) > 0 else {
            layer.opacity = 1
            layer.setValue(1.0, forKeyPath: "transform.scale")
            layer.setValue(0.0, forKeyPath: "transform.translation.y")
            return
        }

        layer.opacity = 0
        switch variant {
        case .fade:
            break
        case .fadeScale:
            if Motion.animatesMovement {
                layer.setValue(0.86, forKeyPath: "transform.scale")
                Motion.set(layer, "transform.scale", to: 1.0, movementFade: .fadeIn, from: 0.86)
            } else {
                layer.setValue(1.0, forKeyPath: "transform.scale")
            }
        case .fadeSlide:
            if Motion.animatesMovement {
                layer.setValue(2.0, forKeyPath: "transform.translation.y")
                Motion.set(layer, "transform.translation.y", to: 0.0, movementFade: .fadeIn, from: 2.0)
            } else {
                layer.setValue(0.0, forKeyPath: "transform.translation.y")
            }
        case .instant:
            break
        }
        Motion.set(layer, "opacity", to: 1.0, fade: .fadeIn, from: 0.0)
    }

    /// Retains the indicator for the duration of a prototype exit so a busy
    /// tab does not flicker out. A new busy update cancels this transition and
    /// retargets the same layer in `showSpinner`.
    private func hideSpinner(_ spinner: StatusIndicatorLayer, animated: Bool) {
        let variant = animated ? TabTunables.loadingAnimation.value : .instant
        let layer = spinner.layer
        layer.removeAnimation(forKey: "opacity")
        layer.removeAnimation(forKey: "transform.scale")
        layer.removeAnimation(forKey: "transform.translation.y")
        guard variant != .instant, Motion.duration(.fadeOut) > 0 else {
            removeSpinner(spinner)
            return
        }

        isSpinnerExiting = true
        layer.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak spinner] in
            MainActor.assumeIsolated {
                guard let self, let spinner, self.spinnerLayer === spinner, !self.item.isBusy else { return }
                self.removeSpinner(spinner)
            }
        }
        switch variant {
        case .fade:
            break
        case .fadeScale:
            if Motion.animatesMovement {
                Motion.set(layer, "transform.scale", to: 0.86, movementFade: .fadeOut)
            }
        case .fadeSlide:
            if Motion.animatesMovement {
                Motion.set(layer, "transform.translation.y", to: 2.0, movementFade: .fadeOut)
            }
        case .instant:
            break
        }
        Motion.set(layer, "opacity", to: 0.0, fade: .fadeOut)
        CATransaction.commit()
    }

    private func removeSpinner(_ spinner: StatusIndicatorLayer) {
        guard spinnerLayer === spinner else { return }
        spinner.layer.removeAllAnimations()
        spinner.layer.removeFromSuperlayer()
        spinnerLayer = nil
        isSpinnerExiting = false
    }

    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        if item.status != .none { updateStatusGlyph() }
        guard item.isBusy else { return }
        updateSpinner()
        updateColors(animated: false)
    }
}
