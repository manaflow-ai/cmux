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
    /// Teardown is retained so a rapid disable/enable or account switch
    /// cannot start a second listener before the first one has closed.
    private var teardown: Task<Void, Never>?
    private var teardownGeneration = 0
    /// Bumped by every start and stop; a start that lost the race drops out.
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile-link")

    /// Starts (or restarts for a new account) the phone link host.
    func start(launch: LaunchIdentity, daemon: DaemonService, setting: MobileLinkSetting = MobileLinkSetting()) {
        // A listener owns the Bonjour name and direct port.  Tear down the
        // previous run in the replacement task, rather than launching an
        // unawaited teardown beside the new assembly.  This matters on an
        // account/team switch: two assemblies must never overlap while they
        // are both trying to advertise the same Mac.
        generation += 1
        starting?.cancel()
        starting = nil
        let previous = runner
        runner = nil
        let priorTeardown = teardown
        teardownGeneration += 1
        let teardownID = teardownGeneration
        let replacementTeardown: Task<Void, Never> = Task { [weak self, previous, priorTeardown] in
            if let priorTeardown { await priorTeardown.value }
            if let previous { await previous.stop() }
            self?.clearTeardown(id: teardownID)
        }
        teardown = replacementTeardown
        let current = generation

        guard setting.enabled else { return }
        guard let provider = accountProvider else {
            logger.info("phone link: not started, no account source")
            return
        }
        let namespace = launch.bundleID ?? "com.cmuxterm.app.next"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let keys = support.appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("mobile-link", isDirectory: true)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let linkServices = servicesProvider?(setting) ?? MobileLinkServices()
        starting = Task { [weak self, logger] in
            await replacementTeardown.value
            guard !Task.isCancelled else { return }
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
                // `start()` may have opened part of the assembly before it
                // failed.  Finalize that run and clear it so a later account
                // transition cannot retain a half-started listener.
                guard let self, self.generation == current else {
                    await runner.stop()
                    return
                }
                self.runner = nil
                await runner.stop()
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
        let priorTeardown = teardown
        teardownGeneration += 1
        let teardownID = teardownGeneration
        teardown = Task { [weak self, runner, priorTeardown] in
            if let priorTeardown { await priorTeardown.value }
            if let runner { await runner.stop() }
            self?.clearTeardown(id: teardownID)
        }
    }

    private func clearTeardown(id: Int) {
        guard teardownGeneration == id else { return }
        teardown = nil
    }
}
