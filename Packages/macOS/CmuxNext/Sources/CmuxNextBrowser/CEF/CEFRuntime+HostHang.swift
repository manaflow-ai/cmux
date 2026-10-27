import AppKit

/// Host mode's watch on the Chromium Host's UI thread (task p01-process-084 of
/// plans/cmux-next/chrome-parity/p01-process.md, feature `chromiumHostHangBanner`): input the host
/// has not dispatched for 2 s while a hosted page shows puts "Chromium is busy" over every pane that
/// shows a hosted page (``ChromiumHostHangMonitor``), and the host's UI hangs go to `reports`.
extension CEFRuntime {
    /// Host mode, before the start (`CEFEngine` after the adopt): makes the host's hang monitor. Each
    /// attached host that acks its dispatch then reports to it. No effect in process or when it exists.
    func watchHostHangs(reports: @escaping (ChromiumHostHang) -> Void) {
        guard let hostStart, hostStart.hangMonitor == nil else { return }
        let monitor = ChromiumHostHangMonitor(deadline: ChromiumHostBusyTimer(wakeUps: wakeUps))
        monitor.onHang = reports
        monitor.onBusyChange = { [weak self] busy in self?.showHostBusy(busy) }
        if hostStart.canReloadHost { monitor.onReload = { [weak hostStart] in hostStart?.reloadHost() } }
        hostStart.hangMonitor = monitor
    }

    /// Shows or takes away the busy banner over each pane that shows a hosted page.
    func showHostBusy(_ busy: Bool) {
        let monitor = busy ? hostStart?.hangMonitor : nil
        for host in hosts.values where host.hostedPageView != nil { host.showHostBusy(monitor) }
    }
}

extension CEFPaneHost {
    /// The busy banner at the top of the pane while `monitor` says the host is busy; nil takes it away.
    func showHostBusy(_ monitor: ChromiumHostHangMonitor?) {
        let shown = hostView.subviews.lazy.compactMap { $0 as? ChromiumHostBusyBanner }.first
        guard let monitor else {
            shown?.removeFromSuperview()
            return
        }
        guard shown == nil else { return }
        let banner = ChromiumHostBusyBanner(wait: { [weak monitor] in monitor?.keepWaiting() },
                                            reload: monitor.canReload ? { [weak monitor] in monitor?.reload() } : nil)
        banner.place(in: hostView)
        hostView.addSubview(banner, positioned: .above, relativeTo: nil)
    }

    /// Host mode: the pane's page view showed or stopped showing; the busy deadline runs only while a
    /// hosted page shows.
    func hostPageShownChanged() {
        guard let page = hostedPageView, let monitor = runtime.hostStart?.hangMonitor else { return }
        monitor.pageShown(ObjectIdentifier(page), page.pageVisibility == .visible)
    }
}

extension CEFEngine {
    /// The host's UI-thread watch (`debug.cef` `host_hang`, chromium-host-bench.py `--hang`): nil without the
    /// feature `chromiumHostHangBanner` or in process. `last_busy_after_ms` is -1 before the first banner.
    public var hostHangCounters: [String: Double]? {
        guard let hostStart = CEFRuntime.shared.hostStart, let monitor = hostStart.hangMonitor else { return nil }
        let busyAfter = monitor.lastBusyAfter.map { Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15 }
        return ["watching": hostStart.watchesHangs ? 1 : 0, "busy": monitor.isBusy ? 1 : 0, "armed": monitor.isArmed ? 1 : 0,
                "shown": monitor.isShown ? 1 : 0, "busy_count": Double(monitor.busyCount),
                "last_busy_after_ms": busyAfter ?? -1, "host_hangs": Double(monitor.hangCount)]
    }
}
