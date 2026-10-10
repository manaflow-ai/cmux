import AppKit
import CmuxNextHistory

// The top row's controls as tests and strips see them: the static sidebar
// toggle and history buttons in the toolbar band (R68, R69), the traffic
// lights, and the badge after them.
extension WindowRootView {
    /// The static sidebar toggle (R68).
    var sidebarToggleButton: NSButton? { toolbarBand.sidebarToggle }
    /// The toggle's frame in window coordinates.
    var sidebarToggleFrame: CGRect? {
        let toggle = toolbarBand.sidebarToggle
        return toggle.convert(toggle.bounds, to: nil)
    }
    /// The window's close, minimize and zoom buttons.
    var trafficLightButtons: [NSView] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }
    /// A click on the toggle (tests).
    func pressSidebarToggle() { toolbarBand.toggle() }
    /// A history button's frame in window coordinates (R69).
    func historyButtonFrame(_ direction: LocationTrailDirection) -> CGRect? {
        let button = toolbarBand.historyButton(direction)
        return button.convert(button.bounds, to: nil)
    }
    /// Whether a history button is enabled (tests).
    func historyButtonEnabled(_ direction: LocationTrailDirection) -> Bool { toolbarBand.historyButton(direction).isEnabled }
    /// A click on a history button (tests).
    func pressHistoryButton(_ direction: LocationTrailDirection) { toolbarBand.onHistory?(direction) }

    /// The badge's frame in window coordinates while it shows.
    var titlebarBadgeFrame: CGRect? {
        guard let badge = titlebarBadge, !badge.isHidden else { return nil }
        return badge.convert(badge.bounds, to: nil)
    }

    /// What strips under the top row keep clear (window coordinates): the
    /// toolbar band and, while it shows, the badge after it.
    var titlebarAccessoryFrame: CGRect {
        let band = toolbarBand.convert(toolbarBand.bounds, to: nil)
        return titlebarBadgeFrame.map { band.union($0) } ?? band
    }
}
