import CmuxNextCompat
import CmuxNextDesign
import QuartzCore

/// The tab's busy indicator: the shared `StatusIndicatorLayer` in the
/// trailing cluster (TabCell+TrailingMarks; in the icon slot only on a tab
/// that shows no title). A busy cell registers with `StatusIndicatorAppearance`, so a
/// settings or Debug Settings change restyles it live; idle cells cost
/// nothing.
extension TabCell: StatusIndicatorConfigClient {
    /// The plan the tab's indicator draws now (hidden when not busy or the
    /// style is `none`).
    var spinnerPlan: StatusIndicatorPlan {
        guard item.indicator.replacesTabIcon else { return .hidden }
        let config = StatusIndicatorAppearance.shared.config
        // A page waiting for its first response spins like every other spinner: same direction,
        // same phase (Lawrence 2026-10-20; Chromium's counter-clockwise waiting throbber put two
        // spinners on screen turning opposite ways).
        return StatusIndicatorPlan.make(item.indicator, style: config.style(hint: item.busyStyle),
                                        animates: config.animatesLoops && isWindowVisible, set: config.iconSet, isStatic: config.isStatic,
                                        staticShapes: config.staticShapes, working: config.workingLook)
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
        layer.removeAnimation(forKey: "transform")
        layer.isHidden = false
        guard variant != .instant, Motion.indicators.duration(.fadeIn) > 0 else {
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            return
        }

        layer.opacity = 0
        switch variant {
        case .fade:
            break
        case .fadeScale:
            if Motion.indicators.animatesMovement {
                layer.transform = prototypeTransform(scale: 0.86)
                Motion.indicators.set(layer, "transform", to: NSValue(caTransform3D: prototypeTransform()), movementFade: .fadeIn,
                           from: NSValue(caTransform3D: prototypeTransform(scale: 0.86)))
            } else {
                layer.transform = CATransform3DIdentity
            }
        case .fadeSlide:
            if Motion.indicators.animatesMovement {
                layer.transform = prototypeTransform(y: 2)
                Motion.indicators.set(layer, "transform", to: NSValue(caTransform3D: prototypeTransform()), movementFade: .fadeIn,
                           from: NSValue(caTransform3D: prototypeTransform(y: 2)))
            } else {
                layer.transform = CATransform3DIdentity
            }
        case .instant:
            break
        }
        Motion.indicators.set(layer, "opacity", to: 1.0, fade: .fadeIn, from: 0.0)
    }

    /// Retains the indicator for the duration of a prototype exit so a busy
    /// tab does not flicker out. A new busy update cancels this transition and
    /// retargets the same layer in `showSpinner`.
    private func hideSpinner(_ spinner: StatusIndicatorLayer, animated: Bool) {
        let variant = animated ? TabTunables.loadingAnimation.value : .instant
        let layer = spinner.layer
        layer.removeAnimation(forKey: "opacity")
        layer.removeAnimation(forKey: "transform")
        guard variant != .instant, Motion.indicators.duration(.fadeOut) > 0 else {
            removeSpinner(spinner)
            return
        }

        isSpinnerExiting = true
        layer.isHidden = false
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self, weak spinner] in
            guard let self, let spinner, self.spinnerLayer === spinner, !self.item.isBusy else { return }
            self.removeSpinner(spinner)
        }
        switch variant {
        case .fade:
            break
        case .fadeScale:
            if Motion.indicators.animatesMovement {
                Motion.indicators.set(layer, "transform", to: NSValue(caTransform3D: prototypeTransform(scale: 0.86)), movementFade: .fadeOut)
            }
        case .fadeSlide:
            if Motion.indicators.animatesMovement {
                Motion.indicators.set(layer, "transform", to: NSValue(caTransform3D: prototypeTransform(y: 2)), movementFade: .fadeOut)
            }
        case .instant:
            break
        }
        Motion.indicators.set(layer, "opacity", to: 0.0, fade: .fadeOut)
        CATransaction.commit()
    }

    private func prototypeTransform(scale: CGFloat = 1, y: CGFloat = 0) -> CATransform3D {
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform = CATransform3DTranslate(transform, 0, y, 0)
        return transform
    }

    private func removeSpinner(_ spinner: StatusIndicatorLayer) {
        guard spinnerLayer === spinner else { return }
        spinner.layer.removeAllAnimations()
        spinner.layer.removeFromSuperlayer()
        spinnerLayer = nil
        isSpinnerExiting = false
    }

    /// Checks the indicator again (the app came back, a window became main, the Mac woke): now
    /// when the strip shows, else when it shows again.
    func statusIndicatorResync() {
        guard isStripShown else {
            owesIndicatorResync = true
            return
        }
        owesIndicatorResync = false
        StatusIndicatorAppearance.resyncs &+= 1
        statusIndicatorConfigDidChange(StatusIndicatorAppearance.shared.config)
    }

    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        if item.status != .none { updateStatusGlyph() }
        guard item.isBusy else { return }
        updateSpinner()
        updateColors(animated: false)
    }
}
