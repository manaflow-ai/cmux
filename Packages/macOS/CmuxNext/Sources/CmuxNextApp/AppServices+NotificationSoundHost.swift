import AppKit
import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextSettings
import CmuxNextWakeups

extension AppServices: NotificationSoundHost {
    var soundPreferences: NotificationPreferences { notifications.preferences }
    func applySoundPreferences(_ sounds: NotificationSoundPreferences) { notifications.preferences.sounds = sounds }
    func writeSoundSetting(_ path: [String], _ value: CmuxNextSettings.JSONValue?, by writer: SettingWriter) async -> ActionWorkFailure? { await AppActionContext(services: self).writeSettingNow(path, value, by: writer) }
    func soundWorkspace(_ invocation: ActionInvocation) throws -> String { try AppActionContext(services: self).workspace(invocation).model.id }
    func soundGroup(_ invocation: ActionInvocation) throws -> NotificationSoundScope.Group { try AppActionContext(services: self).soundGroup(invocation) }
    func soundGroups(ofWorkspace id: String) -> [NotificationSoundScope.Group] { AppActionContext(services: self).soundGroups(ofWorkspace: id) }
    var soundAgentKinds: [String] { AppActionContext(services: self).soundAgentKinds }
    var soundAnchorWindow: NSWindow? { windows.active?.window }
    var soundWork: BackgroundWork { work }
    func soundRefusal(_ error: any Error) -> String { RefusalStrings.describe(error) }
}
