import Foundation
import Testing
@testable import CmuxMobileModel

/// Settings → Notifications (verify/rich-push.md): three levels, per-Mac
/// off and Show previews, migrated from the three earlier switches.
@MainActor @Suite struct NotificationLevelTests {
    func defaults() -> UserDefaults {
        let name = "notification-level-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func eachLevelAsksForItsKinds() {
        #expect(NotificationLevel.needed.kinds == ["question", "permission"])
        #expect(NotificationLevel.neededAndFinished.kinds == ["question", "permission", "completed", "chief"])
        #expect(NotificationLevel.everything.kinds == ["question", "permission", "completed", "chief", "failed", "terminal"])
    }

    @Test func aNewInstallGetsNeededAndFinishedWithPreviews() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.notifyLevel == .neededAndFinished)
        #expect(store.notifyPreviews)
        #expect(store.notifyMutedMacs.isEmpty)
    }

    @Test func theEarlierSwitchesMigrate() {
        let finishedOff = defaults()
        finishedOff.set(false, forKey: "cmuxMobile.settings.notifyFinished")
        #expect(SettingsStore(defaults: finishedOff).notifyLevel == .needed)
        let errorsOff = defaults()
        errorsOff.set(false, forKey: "cmuxMobile.settings.notifyErrors")
        #expect(SettingsStore(defaults: errorsOff).notifyLevel == .neededAndFinished)
        // Questions off (review low): asks always push now; finished still decides the level.
        let questionsOff = defaults()
        questionsOff.set(false, forKey: "cmuxMobile.settings.notifyQuestions")
        #expect(SettingsStore(defaults: questionsOff).notifyLevel == .neededAndFinished)
        let onlyErrors = defaults()
        onlyErrors.set(false, forKey: "cmuxMobile.settings.notifyQuestions")
        onlyErrors.set(false, forKey: "cmuxMobile.settings.notifyFinished")
        #expect(SettingsStore(defaults: onlyErrors).notifyLevel == .needed)
    }

    @Test func choicesPersist() {
        let d = defaults()
        let store = SettingsStore(defaults: d)
        store.notifyLevel = .everything
        store.notifyPreviews = false
        store.setNotifications(macID: "m1", on: false)
        store.setNotifications(macID: "m2", on: false)
        store.setNotifications(macID: "m2", on: true)
        let again = SettingsStore(defaults: d)
        #expect(again.notifyLevel == .everything && !again.notifyPreviews && again.notifyMutedMacs == ["m1"])
        #expect(!again.notifies(macID: "m1") && again.notifies(macID: "m2"))
    }
}
