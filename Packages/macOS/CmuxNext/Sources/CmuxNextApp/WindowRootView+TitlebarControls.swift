import AppKit
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextTraceUI

// The top row's controls as tests and strips see them: the static sidebar
// toggle and history buttons in the toolbar band (R68, R69), the traffic
// lights, and the badge after them.
extension WindowRootView {
    /// The toggle's frame in window coordinates.
    var sidebarToggleFrame: CGRect? {
        let toggle = toolbarBand.sidebarToggle
        return toggle.convert(toggle.bounds, to: nil)
    }
    /// A history button's frame in window coordinates (R69).
    func historyButtonFrame(_ direction: LocationTrailDirection) -> CGRect? {
        let button = toolbarBand.historyButton(direction)
        return button.convert(button.bounds, to: nil)
    }

    /// The badge's frame in window coordinates while it shows.
    var titlebarBadgeFrame: CGRect? {
        guard let badge = titlebarBadge, !badge.isHidden else { return nil }
        return badge.convert(badge.bounds, to: nil)
    }

    /// What strips under the top row keep clear (window coordinates): the
    /// toolbar band and, while they show, the badge and the indicators after it.
    var titlebarAccessoryFrame: CGRect {
        let band = toolbarBand.convert(toolbarBand.bounds, to: nil)
        let indicators = topRowIndicators.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }
        return ([titlebarBadgeFrame].compactMap(\.self) + indicators).reduce(band) { $0.union($1) }
    }

    /// After the band, the badge while `showsTitlebarBadge`, then the host
    /// pressure and trace recording indicators while they show, `space2` apart,
    /// centered on `midY`.
    func layoutTitlebarAccessories(midY: CGFloat) {
        var x = toolbarBand.frame.maxX + Metrics.space2
        if let badge = titlebarBadge {
            badge.isHidden = !showsTitlebarBadge
            if showsTitlebarBadge {
                let size = badge.fittingSize
                badge.frame = CGRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
                x = badge.frame.maxX + Metrics.space2
            }
        }
        let side = TitlebarBandButton.side
        for indicator in topRowIndicators where !indicator.isHidden {
            let width = (indicator as? HostPressureIndicatorView)?.width ?? (indicator as? TraceRecordingIndicatorView)?.width ?? side
            indicator.frame = CGRect(x: x, y: (midY - side / 2).rounded(), width: width, height: side)
            x = indicator.frame.maxX + Metrics.space2
        }
    }
}
