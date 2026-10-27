import CmuxNextDesign
import CmuxNextWakeups

/// The two settings a page follows whether it shows or not (p06-scheduler.md section C, rule 3): the page zoom and
/// interface scale (`--cmux-interface-scale`), and the static status look (`data-status-indicators`, cx-sya4n) in
/// its theme. Each is a push to the page, not a view apply, so it must reach a hidden page too (ThemeFollower's rule):
/// the page's first frame after a show is at the new scale and look. Each change is one posted `visible` task on
/// the app's scheduler, coalesced per burst (``ServiceObservation``). Chrome sends a zoom change to every page of
/// the host, hidden or not, in the same way (`HostZoomMapImpl::SendZoomLevelChange`, content/browser/host_zoom_map_impl.cc).
@MainActor
final class PageSettingsPushes {
    /// What the page zoom and the interface scale token read.
    nonisolated struct Scale: Equatable, Sendable {
        var uiScale: Double
        var interfaceScale: Double
        var interfaceScaleEnabled: Bool
    }

    private let scale: ServiceObservation<Scale>
    private let statusLook: ServiceObservation<StatusIndicatorAnimation>

    /// Starts following both settings for `page` on `work`, and applies the current scale and look before it returns.
    init(_ page: PageWebView, on work: MainWorkScheduler) {
        scale = ServiceObservation(.visible, owner: "PageWebView.uiScale", on: work) {
            let design = DesignSettings.shared
            return Scale(uiScale: Double(design.uiScale), interfaceScale: Double(design.interfaceScale),
                         interfaceScaleEnabled: design.interfaceScaleEnabled)
        } apply: { [weak page] _ in
            page?.applyUIScale()
        }
        statusLook = ServiceObservation(.visible, owner: "PageWebView.statusLook", on: work) {
            DesignSettings.shared.statusIndicator.animation
        } apply: { [weak page] _ in
            page?.applyTheme()
        }
    }
}
