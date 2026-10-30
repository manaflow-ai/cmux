import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// The notification a finished `cmux status run` posts on its terminal's tab:
/// "<label> is done" with how long it took, or "<label> failed" with the exit
/// code, in the app's language.
struct StatusRunNotice: Hashable {
    var title: String
    var body: String
    var level: NotificationLevel
    /// The run's terminal tab, nil when it is not in this client's store.
    var surface: SurfaceID?

    init(title: String, body: String, level: NotificationLevel, surface: SurfaceID?) {
        self.title = title
        self.body = body
        self.level = level
        self.surface = surface
    }

    /// The notice for `run`, worded in `localizations` (the first is the duration's locale).
    init(_ run: FinishedStatusRun, surface: SurfaceID?, localizations: [String]) {
        func text(_ key: String, _ english: String) -> String {
            Bundle.module.localizedString(forKey: key, value: english, table: "NotificationsPanel",
                                          preferredLocalizations: localizations)
        }
        let locale = Locale(identifier: localizations.first ?? "en")
        let took = Duration.milliseconds(Int64(clamping: run.durationMs ?? 0))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(locale))
        // The OSC 7501 alert wording ("make is done", "make failed"), so both kinds of finish read alike.
        if run.succeeded {
            title = String(format: text("notifications.programAlert.done", "%@ is done"), run.label)
            body = String(format: text("notifications.statusRun.took", "Took %@"), took)
            level = .info
        } else {
            title = String(format: text("notifications.programAlert.failed", "%@ failed"), run.label)
            let code = run.exitCode.map(String.init) ?? "?"
            body = String(format: text("notifications.statusRun.exitAfter", "Exit code %1$@ after %2$@"), code, took)
            level = .error
        }
        self.surface = surface
    }
}
