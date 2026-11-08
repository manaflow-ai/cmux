import CmuxUpdater
import Foundation

/// The install the person waits on (a583): how long it has run, and a give-up that brings the
/// click-hidden windows back when no relaunch comes (``UpdateInstallStatus``).
extension UpdaterService {
    /// The running install's status, or nil outside the install phase. Read by the notice card.
    public var installStatus: UpdateInstallStatus? {
        _ = installTick
        guard let started = installStartedAt else { return nil }
        let elapsed = Duration.milliseconds(Int64(max(0, now().timeIntervalSince(started)) * 1000))
        return UpdateInstallStatus(elapsed: elapsed)
    }

    /// Starts the install's clock when the phase becomes installing; stops it on any other phase.
    func followInstall(_ phase: UpdateIndicatorPhase) {
        if phase == .installing {
            guard installStartedAt == nil else { return }
            installStartedAt = now()
            installGaveUp = false
            installCardDismissed = false
            log.append("install: started; waiting for the installer and the relaunch")
            scheduleInstallTick()
        } else if let started = installStartedAt {
            log.append("install: phase ended after \(Int(now().timeIntervalSince(started))) s without a relaunch")
            installStartedAt = nil
            installCardDismissed = false
            installTimer.cancel()
        }
    }

    private func scheduleInstallTick() {
        // A one-second deadline while an install runs: the card's seconds, then the give-up.
        installTimer.schedule(after: .seconds(1)) { @MainActor [weak self] in self?.installTicked() }
    }

    private func installTicked() {
        guard let status = installStatus else { return }
        installTick &+= 1
        if status.stage == .stalled {
            guard !installGaveUp else { return }
            installGaveUp = true
            log.append("install: no relaunch after \(status.seconds) s; the windows come back")
            abandonInstall()
            return
        }
        if status.seconds == Int(UpdateInstallStatus.slowAfter.components.seconds) {
            log.append("install: still waiting after \(status.seconds) s")
        }
        scheduleInstallTick()
    }
    /// The install ended with this app running: its relaunch record goes (``UpdateInstallCheck``), the windows come back.
    func abandonInstall() { UpdateInstallCheck.write(nil, defaults: defaults); installAbandoned?() }
}
