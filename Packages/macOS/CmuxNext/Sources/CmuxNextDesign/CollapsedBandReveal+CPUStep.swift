import AppKit
import CmuxNextDesignTokens

/// The reveal's CPU-stepped variant (`motion.renderServer` off, the `cpuStep` backend of chrome-parity
/// R2): the open share is the width of ``CollapsedBandReveal/driver``, a constraint animated with the
/// sidebar's tokens. Every animation frame lays the window root out, which places the band and the
/// strips under it in the same pass, the same way the sidebar's own width drives the band. A change
/// mid-animation retargets from what is on screen. It goes with the other `cpuStep` paths after task
/// p03-rendering-022c and one Nightly.
extension CollapsedBandReveal {
    /// The stepped share on screen: 0 closed, 1 open, in between while it animates.
    var steppedPresence: CGFloat {
        let full = fullWidth()
        return full > 0 ? min(1, max(0, driver.frame.width / full)) : 0
    }

    /// Adds the driver to `root` (top-leading, 0 tall).
    func installDriver(in root: NSView) {
        driver.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(driver)
        let width = driver.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            driver.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            driver.topAnchor.constraint(equalTo: root.topAnchor),
            driver.heightAnchor.constraint(equalToConstant: 0),
            width,
        ])
        driverWidth = width
    }

    /// Animates the driver to `share` of the band's width, or sets it under Reduce Motion, speed off or a
    /// window with no screen (``lastChangeAnimated``).
    func step(to share: CGFloat) {
        stepped = true
        guard let width = driverWidth else { return }
        let target = share * fullWidth()
        lastChangeAnimated = Motion.sidebar.policy.animatesMovement && Motion.canAnimate(in: driver)
        guard lastChangeAnimated else { width.constant = target; return }
        guard share > 0 else {
            Motion.sidebar.animateExit(.disappear, in: driver) { Motion.animator(width, in: driver).constant = target }
            return
        }
        // Start from what shows (a sidebar that is still sliding out), so the band never dips.
        let start = max(presence, shownPresence()) * fullWidth()
        if start > width.constant {
            Motion.withoutAnimation { Motion.animator(width, in: driver).constant = start }
        }
        Motion.sidebar.animateTimed(.appear, in: driver) { Motion.animator(width, in: driver).constant = target }
    }

    /// Puts the driver at a render-server change's share, so a later stepped change starts from it.
    func park(at share: CGFloat) {
        driverWidth?.constant = share * fullWidth()
    }
}

/// Carries the stepped share as its width; takes no clicks, draws nothing.
final class ShareDriverView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
