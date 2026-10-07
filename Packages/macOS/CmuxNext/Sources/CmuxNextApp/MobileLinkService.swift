import CmuxNextControl
import CmuxNextMobileConnect
import Foundation
import os

/// The cmux.mobile/1 phone link host (d1-terminal-ux.md, Mac wiring),
/// started by `MobileHostService` next to its irx host (the one the shipping phone
/// uses) when `MobileLinkSetting.enabled`. It runs as the Mac's backend install
/// principal (`MobileLinkHostAccount`, `CloudMobileLinkAccount`), which
/// `AppServices` supplies for the signed-in account.
final class MobileLinkService {
    /// The install principal for the signed-in account, given the Mac's name;
    /// nil while signed out.
    var accountProvider: (@MainActor (String) -> (any MobileLinkHostAccount)?)?
    /// The app's files, git, browser, remote desktop, tunnel, simulator and task services (D1b).
    var servicesProvider: (@MainActor (MobileLinkSetting) -> MobileLinkServices)?
    private var runner: MobileLinkHostRunner?
    private var starting: Task<Void, Never>?
    /// Bumped by every start and stop; a start that lost the race drops out.
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile-link")

    /// Starts (or restarts for a new account) the phone link host.
    func start(launch: LaunchIdentity, daemon: DaemonService, setting: MobileLinkSetting = MobileLinkSetting()) {
        stop()
        guard setting.enabled else { return }
        guard let provider = accountProvider else {
            logger.info("phone link: not started, no account source")
            return
        }
        generation += 1
        let current = generation
        let namespace = launch.bundleID ?? "com.cmuxterm.app.next"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let keys = support.appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("mobile-link", isDirectory: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let linkServices = servicesProvider?(setting) ?? MobileLinkServices()
        starting = Task { [weak self, logger] in
            let name = await MacName.computerName()
            guard let self, self.generation == current, !Task.isCancelled else { return }
            guard let account = provider(name) else {
                logger.info("phone link: not started, signed out")
                return
            }
            let runner = MobileLinkHostRunner(
                account: account,
                options: MobileLinkHostOptions(macName: name, appVersion: version,
                                               wireGuardOverWebRTC: setting.wireGuardOverWebRTC, keyDirectory: keys,
                                               services: linkServices),
                endpointProvider: { @MainActor in try await daemon.endpoint() })
            self.runner = runner
            do {
                _ = try await runner.start()
            } catch {
                logger.error("phone link: start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        generation += 1
        starting?.cancel()
        starting = nil
        let runner = runner
        self.runner = nil
        // task-owner: teardown hop; MobileLinkHostRunner.stop() is idempotent
        Task { await runner?.stop() }
    }
}
