import AppKit
import CmuxNextDesign
import CmuxNextHistory

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
    /// toolbar band and, while they show, the badge, the host pressure
    /// indicator and the live mode badge after it.
    var titlebarAccessoryFrame: CGRect {
        let band = toolbarBand.convert(toolbarBand.bounds, to: nil)
        let shown = [titlebarBadgeFrame] + [hostPressureIndicator, liveModeBadge].map { $0.flatMap { $0.isHidden ? nil : $0.convert($0.bounds, to: nil) } }
        return shown.compactMap(\.self).reduce(band) { $0.union($1) }
    }

    /// After the band, the badge while `showsTitlebarBadge`, then the host
    /// pressure indicator while it shows, `space2` apart, centered on `midY`.
    func layoutTitlebarAccessories(midY: CGFloat) {
        titlebarBadge?.isHidden = !showsTitlebarBadge || presentsPage
        WindowTitlebar.layoutAccessories(after: toolbarBand.frame, badge: showsTitlebarBadge ? titlebarBadge : nil,
                                        indicator: hostPressureIndicator,
                                        indicatorWidth: (hostPressureIndicator as? HostPressureIndicatorView)?.width ?? TitlebarBandButton.side,
                                        centeredOn: midY, scale: window?.backingScaleFactor ?? 1, trailing: liveModeBadge)
    }
}
