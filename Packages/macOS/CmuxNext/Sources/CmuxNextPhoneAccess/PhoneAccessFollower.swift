import CmuxNextCompat
import CmuxNextMobile
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import os

/// Applies Settings > Accounts > Phone Access: the phone listener runs only
/// while `phone.allowConnections` is on, and `phone.startSessions` reaches
/// every phone request through the host's `PhoneAccessGate`.
final class PhoneAccessFollower {
    private let mobile: MobileHostService
    private let settings: SettingsController
    private let history: MobileHostHistory
    /// The load and the one-time migration, then the settings follow; app lifetime.
    private var starting: Task<Void, Never>?
    /// The settings follow, once the migration ran.
    private var observation: ServiceObservation<Access>?

    /// The two settings the listener follows, applied together.
    nonisolated struct Access: Equatable, Sendable {
        var allowed: Bool
        var startsSessions: Bool
    }

    init(mobile: MobileHostService, settings: SettingsController, history: MobileHostHistory) {
        self.mobile = mobile
        self.settings = settings
        self.history = history
    }

    func start() {
        guard starting == nil else { return }
        starting = Task { [weak self, settings, history] in
            await settings.waitForLoad(atLeast: 1)
            await PhoneAccessMigration.run(settings: settings, history: history)
            self?.follow()
        }
    }

    /// `visible`: Settings > Accounts > Phone Access shows the listener's state; a person's toggle applies in
    /// their turn.
    private func follow() {
        guard observation == nil else { return }
        let mobile = mobile, settings = settings
        observation = ServiceObservation(.visible, owner: "PhoneAccessFollower.settings", on: mobile.mainWork) {
            Access(allowed: settings.snapshot.sessions.allowsPhone, startsSessions: settings.snapshot.sessions.phoneStartsSessions)
        } apply: { [weak mobile] access in
            mobile?.access.setAllowsStartingSessions(access.startsSessions)
            mobile?.setAllowed(access.allowed)
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
