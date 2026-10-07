import CmuxMobileHost
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextMobileConnect
import CmuxNextMobileHostUI
import Foundation

/// The phone link's services from the app (D1b): browser pages over the
/// app's tabs (C2), remote desktop with the consent panel and menu bar
/// indicator (C3; VNC off unless the Mac setting allows it, loopback blocked
/// unless allowed too), the Simulator capture host and the tunnel allowlist
/// (C14), and the task runner over this Mac's acpmux (C8). Files (C4) and git
/// (C13) need only the daemon; the runner builds them.
enum AppMobileLinkServices {
    @MainActor static func make(_ services: AppServices, setting: MobileLinkSetting) -> MobileLinkServices {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let acpmux = AcpmuxEnvironment.resolve(tag: services.environment.tag, bundledBinDirectory: bin,
                                               environment: ProcessInfo.processInfo.environment)
        let agentHost = (try? services.cloud.localDeviceID()).map(AgentSessionRef.host(installID:))
        let vnc: RemoteDesktopVncPolicy = setting.vncEnabled ? .allowed(allowLoopback: setting.vncAllowsLoopback) : .off
        let menu = services.remoteDesktopMenu
        // Typed up front so the closure is formed @Sendable (it captures only
        // a String); Xcode 26.6 rejects converting an inferred closure later.
        let socketPath: (@Sendable () async -> String?)? = (acpmux?.socketPath).map { path in { @Sendable in path } }
        return MobileLinkServices(
            browserPages: TabBrowserPages(tabs: AppMobileBrowserTabs(services: services)),
            remoteDesktop: { names in
                RemoteDesktopChannelHandler(
                    sources: ScreenDesktopSources(pasteboard: GeneralRemoteDesktopPasteboard()),
                    permissions: SystemRemoteDesktopPermissions(),
                    consent: PanelRemoteDesktopConsent(deviceName: names),
                    indicator: MenuBarRemoteDesktopIndicator(menu: menu, deviceName: names),
                    policy: RemoteDesktopPolicy(vnc: vnc))
            },
            simulators: SimulatorAppCaptureHost(),
            allowedPorts: setting.tunnelAllowedPorts,
            acpmuxSocketPath: socketPath,
            agentHost: agentHost, agentHostName: nil,
            agentHomes: AgentHome.standard.map { URL(fileURLWithPath: $0.base, isDirectory: true) },
            allowsTaskDispatch: setting.allowsTaskDispatch, allowsTerminalSpawn: setting.allowsTerminalSpawn)
    }
}
