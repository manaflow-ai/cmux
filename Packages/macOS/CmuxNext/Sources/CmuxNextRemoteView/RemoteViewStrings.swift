import Foundation

/// Strings of the remote desktop pane (Resources/Localizable.xcstrings).
nonisolated enum RemoteViewStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var modeView: String { t("rd.mode.view", "View") }
    static var modeControl: String { t("rd.mode.control", "Control") }
    static func display(_ number: Int) -> String { String(format: t("rd.toolbar.display", "Display %lld"), number) }
    static var displayPlaceholder: String { t("rd.toolbar.displayPlaceholder", "Other displays appear here when the host has them") }
    static var quality: String { t("rd.toolbar.quality", "Quality") }
    static var stop: String { t("rd.toolbar.stop", "Stop") }

    static func quality(_ preset: RemoteQualityPreset) -> String {
        switch preset {
        case .auto: t("rd.quality.auto", "Auto")
        case .sharpText: t("rd.quality.sharpText", "Sharp Text")
        case .smoothMotion: t("rd.quality.smoothMotion", "Smooth Motion")
        case .lowBandwidth: t("rd.quality.lowBandwidth", "Low Bandwidth")
        }
    }

    static func path(_ path: RemotePath) -> String {
        switch path {
        case .direct: t("rd.path.direct", "direct")
        case .viaCloudRegion: t("rd.path.viaCloudRegion", "via cloud region")
        case .relayed: t("rd.path.relayed", "relayed")
        }
    }

    static func milliseconds(_ value: Int) -> String { String(format: t("rd.metric.ms", "%lld ms"), value) }
    static var statusConnecting: String { t("rd.status.connecting", "connecting") }
    static var statusEnded: String { t("rd.status.ended", "ended") }

    static func connectingTitle(_ host: String) -> String { String(format: t("rd.state.connecting.title", "Connecting to %@…"), host) }
    static var connectingDetail: String { t("rd.state.connecting.detail", "Finding the fastest path to this machine.") }
    static func consentTitle(_ host: String) -> String { String(format: t("rd.state.consent.title", "Waiting for consent on %@…"), host) }
    static func consentDetail(_ host: String) -> String {
        String(format: t("rd.state.consent.detail", "Someone at %@ must allow this session."), host)
    }

    static func kickedTitle(_ name: String) -> String { String(format: t("rd.state.kicked.title", "Disconnected by %@"), name) }
    static func kickedDetail(_ name: String, _ host: String) -> String {
        String(format: t("rd.state.kicked.detail", "%1$@ ended your session on %2$@."), name, host)
    }

    static var stoppedTitle: String { t("rd.state.stopped.title", "Host stopped sharing") }
    static func stoppedDetail(_ host: String) -> String {
        String(format: t("rd.state.stopped.detail", "%@ turned off Remote Desktop. The last frame is shown."), host)
    }

    static var viewerStoppedTitle: String { t("rd.state.viewerStopped.title", "Session ended") }
    static var viewerStoppedDetail: String { t("rd.state.viewerStopped.detail", "You stopped this session.") }
    static var lostTitle: String { t("rd.state.lost.title", "Connection lost") }
    static func lostDetail(_ host: String) -> String { String(format: t("rd.state.lost.detail", "The path to %@ closed."), host) }
    static var deniedTitle: String { t("rd.state.denied.title", "Not allowed") }
    static func deniedDetail(_ host: String) -> String {
        String(format: t("rd.state.denied.detail", "%@ did not allow this session."), host)
    }

    static var latencyTitle: String { t("rd.state.latency.title", "View only: high latency") }
    static func latencyDetail(rtt: Int, path: String, limit: Int) -> String {
        String(format: t("rd.state.latency.detail", "%1$lld ms, %2$@. Control turns off above %3$lld ms."), rtt, path, limit)
    }

    static var developmentOnly: String {
        t("rd.state.developmentOnly", "Development only: connect to loopback or a single-tenant overlay")
    }

    static var controlAnyway: String { t("rd.action.controlAnyway", "Control Anyway") }
    static var reconnect: String { t("rd.action.reconnect", "Reconnect") }
    static var cancel: String { t("rd.action.cancel", "Cancel") }
    static var close: String { t("rd.action.close", "Close") }
    static var genericTabTitle: String { t("rd.tab.title.generic", "Remote Desktop") }
    static var unavailableTitle: String { t("rd.tab.unavailable.title", "Remote desktop is not available") }
    static var unavailableNotInBuild: String {
        t("rd.tab.unavailable.notInBuild", "This build does not include remote desktop. It is in development builds only for now.")
    }
    static func unavailableNoTransport(_ host: String) -> String {
        String(format: t("rd.tab.unavailable.noTransport", "This build cannot connect to %@ yet. The host “mock” shows a test desktop."), host)
    }
    static func unavailableNotLoopback(_ host: String) -> String {
        String(format: t("rd.tab.unavailable.notLoopback", "Development builds connect only to this Mac for now, not to %@."), host)
    }
    static var unavailableRemoteRecord: String {
        t("rd.tab.unavailable.remoteRecord", "This tab came from another machine. Remote desktop tabs open only on the Mac that made them.")
    }
    static func confirmTitle(_ host: String) -> String { String(format: t("rd.tab.confirm.title", "Connect to %@?"), host) }
    static var confirmDetail: String {
        t("rd.tab.confirm.detail", "A script, an agent or a restore opened this tab. Nothing connects until you choose Connect.")
    }
    static var connect: String { t("rd.action.connect", "Connect") }
    static var unavailableInvalidAddress: String {
        t("rd.tab.unavailable.invalidAddress", "This tab's remote desktop address is not valid.")
    }
    static func accessibilityPane(_ host: String) -> String { String(format: t("rd.a11y.pane", "Remote desktop: %@"), host) }
}
