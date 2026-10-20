import CmuxNextCompat
import CmuxNextMobile
import CmuxNextSettings
import Foundation
import os

/// Applies Settings > Accounts > Phone Access: the phone listener runs only
/// while `phone.allowConnections` is on, `phone.startSessions` reaches every
/// phone request through the host's `PhoneAccessGate`, and `phone.newDevices`
/// decides who asks (`PhoneAdmission`).
final class PhoneAccessFollower {
    private let mobile: MobileHostService
    private let settings: SettingsController
    private let history: MobileHostHistory
    /// The settings observation; app lifetime.
    private var observation: Task<Void, Never>?

    init(mobile: MobileHostService, settings: SettingsController, history: MobileHostHistory) {
        self.mobile = mobile
        self.settings = settings
        self.history = history
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [mobile, settings, history] in
            await settings.waitForLoad(atLeast: 1)
            await PhoneAccessMigration.run(settings: settings, history: history)
            for await sessions in ObservationStream({ settings.snapshot.sessions }) {
                mobile.access.setAllowsStartingSessions(sessions.phoneStartsSessions)
                mobile.admission?.mode = sessions.phoneNewDevices
                mobile.setAllowed(sessions.allowsPhone)
            }
        }
    }
}

/// Phone access became opt-in (off on a fresh install). A Mac whose phone
/// host already ran under the old always-on behavior keeps serving phones:
/// once, when `phone.allowConnections` is unset, it is written on. A flag in
/// user defaults makes it once, so a later reset to the default stays off.
enum PhoneAccessMigration {
    static let doneKey = "cmux.phoneAccess.migrated.v1"

    /// What the migration writes, if anything: true for a Mac that served phones
    /// and never chose; nil when it ran before or the person already chose.
    nonisolated static func decide(alreadyRan: Bool, chosen: Bool, servedPhones: Bool) -> Bool? {
        guard !alreadyRan, !chosen, servedPhones else { return nil }
        return true
    }

    static func run(settings: SettingsController, history: MobileHostHistory, defaults: UserDefaults = .standard) async {
        let alreadyRan = defaults.bool(forKey: doneKey)
        let chosen = settings.snapshot.root.value(at: SessionSettings.allowConnectionsPath) != nil
        // A directory read: off the main actor.
        let served = alreadyRan || chosen ? false : await Task.detached { history.servedPhones }.value
        guard let on = decide(alreadyRan: alreadyRan, chosen: chosen, servedPhones: served) else {
            defaults.set(true, forKey: doneKey)
            return
        }
        do {
            // The app keeps the person's existing behavior on their behalf; a failed
            // write leaves the flag unset, so the next launch tries again.
            try await settings.setSetting(at: SessionSettings.allowConnectionsPath, to: .bool(on), by: .user)
            defaults.set(true, forKey: doneKey)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile")
                .error("phone access migration not written: \(String(describing: error), privacy: .public)")
        }
    }
}
