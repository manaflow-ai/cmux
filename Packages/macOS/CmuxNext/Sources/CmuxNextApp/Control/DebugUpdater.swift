import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater

/// `debug.updater {action: "relaunch"}` (DEV and NIGHTLY): drives the
/// updater's relaunch path exactly as Sparkle does before it relaunches
/// into an update, then terminates. R138 check update-relaunch-no-prompt.
/// `{action: "stage", version?, changes?}` shows a staged update with fake
/// release notes (UPDATE-CARD screenshots; nothing downloads or installs);
/// `{action: "unstage"}` follows the real updater again. `{action: "tip",
/// id?}` shows a "Did you know" tip; `{action: "untip"}` hides it.
/// `{action: "updated", previous?}` records `previous` (default "0.0.1")
/// as the last seen version, so this launch
/// shows the "cmux Updated!" card (cx-7py7); `{action: "share"}` opens the
/// Share cmux modal and `{action: "share-copy"}` presses its Copy Link.
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
            let version = params["version"]?.stringValue ?? "1.99.0"
            let count = max(0, Int(params["changes"]?.doubleValue ?? 12))
            services.updater.debugStage(version: version, notes: fakeNotes(version: version, changes: count))
            return .object(["staged": .string(version), "changes": JSONValue(count)])
        case "tip":
            services.updater.debugShowTip(params["id"]?.stringValue ?? TipCatalog.all.first?.id)
            return .object(["tip": services.updater.tip.map { .string($0.id) } ?? .null])
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
        case "unstage":
            services.updater.debugStage(version: nil, notes: nil)
            return .object(["staged": .null])
        default:
            throw ControlError.invalidParams("debug.updater: action must be \"relaunch\", \"stage\", \"unstage\", \"tip\", \"untip\", \"updated\", \"share\" or \"share-copy\"")
        }
    }

    /// Release notes for a fake staged update: `changes` items, newest
    /// first, each with an author and a PR number.
    static func fakeNotes(version: String, changes: Int) -> ReleaseNotes {
        let titles = ["Update card with release notes above the sidebar footer", "Restart to update keeps terminals and agents running",
                      "Faster workspace switching with many tabs", "Browser tabs restore their scroll position",
                      "Agent pane remembers the last model", "Fix a crash when closing a split during a drag"]
        let authors = ["lawrencecchen", "contributor", "maintainer"]
        let items = (0..<changes).map { index in
            ReleaseNotes.ChangeItem(title: titles[index % titles.count], author: authors[index % authors.count], pr: 18_000 - index)
        }
        return ReleaseNotes(version: 1, build: "0", shortVersion: version, date: "", highlights: [],
                            changes: items.map(\.title), items: items)
    }

    static func terminate() {
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }
}
