import AppKit
import CmuxNextCompatAppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater

/// `debug.updater {action: "relaunch"}` (DEV and NIGHTLY): drives the
/// updater's relaunch path exactly as Sparkle does before it relaunches
/// into an update, then terminates. R138 check update-relaunch-no-prompt.
/// `{action: "stage", version?, changes?}` shows a staged update with fake
/// release notes (UPDATE-CARD screenshots; nothing downloads or installs);
/// `{action: "simulate"}` stages one with real published notes, as Debug Settings "Simulate
/// pending update" does (`UpdateSimulation.simulate`);
/// `{action: "unstage"}` follows the real updater again. `{action: "tip",
/// id?}` shows a "Did you know" tip; `{action: "untip"}` hides it;
/// `{action: "tips", press?, at?}`: `UpdaterService.debugTips`.
/// `{action: "available", version?}` shows a found, not downloaded update (the notice card);
/// `{action: "snooze", press?, at?}`: `UpdaterService.debugSnooze` (UPDATE-CARD-CLOSE).
/// `{action: "updated", previous?}` records `previous` (default "0.0.1")
/// as the last seen version, so this launch
/// shows the "cmux Updated!" card (cx-7py7); `{action: "share"}` opens the
/// Share cmux modal and `{action: "share-copy"}` presses its Copy Link.
/// `{action: "feedCards"}` posts sample installed-update Feed cards (cmux and Claude Code).
@MainActor
enum DebugUpdater {
    static func run(_ params: [String: JSONValue], _ services: AppServices,
                    terminate: @escaping @MainActor () -> Void = DebugUpdater.terminate) throws -> JSONValue {
        switch params["action"]?.stringValue {
        case "relaunch":
            // What Sparkle does: the relaunch hook (the quit keeps every
            // session), then NSApp.terminate through applicationShouldTerminate.
            services.updater.updaterWillRelaunchApplication()
            terminate()
            return .object(["relaunching": true])
        case "stage":
            let staged = UpdateSimulation.stageSample(services.updater, version: params["version"]?.stringValue, changes: params["changes"]?.doubleValue)
            return .object(["staged": .string(staged.version), "changes": JSONValue(staged.changes)])
        case "simulate": return .object(["simulating": .bool(true), "publishedNotes": .bool(UpdateSimulation(updater: services.updater).simulate())])
        case "available":
            services.updater.debugIndicatorPhase = .available(version: params["version"]?.stringValue ?? "1.99.0")
            return .object(["notice": .string(services.updater.card?.kind ?? "none")])
        case "snooze":
            return .object(services.updater.debugSnooze(press: params["press"]?.stringValue, at: params["at"]?.doubleValue).mapValues(JSONValue.string))
        case "tip":
            services.updater.debugShowTip(params["id"]?.stringValue ?? TipCatalog.all.first?.id)
            return .object(["tip": services.updater.tip.map { .string($0.id) } ?? .null])
        case "tips":
            return .object(services.updater.debugTips(press: params["press"]?.stringValue, at: params["at"]?.doubleValue).mapValues(JSONValue.string))
        case "untip":
            services.updater.debugShowTip(nil)
            return .object(["tip": .null])
        case "updated":
            let previous = params["previous"]?.stringValue ?? "0.0.1"
            guard services.updater.whatsNew.debugPretendUpdated(from: previous) else {
                throw ControlError.invalidParams("debug.updater updated: previous must be a version older than \(services.updater.identity.shortVersion)")
            }
            return .object(["updatedCard": .bool(services.updater.whatsNew.showsUpdatedCard)])
        case "share":
            ShareCmuxPresenter.present(services)
            return .object(["shown": .bool(ShareCmuxPresenter.shown != nil)])
        case "share-copy":
            guard let view = ShareCmuxPresenter.shown else { throw ControlError.invalidParams("debug.updater share-copy: the Share cmux modal is not open") }
            view.copyMessage()
            return .object(["copied": .string(view.messageText)])
        case "feedCards":
            return .object(["posted": JSONValue(UpdateFeedPosting.postSamples(services))])
        case "unstage":
            services.updater.debugStage(version: nil, notes: nil)
            return .object(["staged": .null])
        default:
            throw ControlError.invalidParams("debug.updater: action must be \"relaunch\", \"stage\", \"simulate\", \"unstage\", \"available\", \"snooze\", \"tip\", \"tips\", \"untip\", \"updated\", \"feedCards\", \"share\" or \"share-copy\"")
        }
    }

    static func terminate() {
        NSApplication.terminateFromRunLoop()
    }
}
