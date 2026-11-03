public import CmuxNextControl
import CmuxNextSettings
public import CmuxNextUpdater
public import Foundation

/// The control methods that move this Mac to another build, for the App's control router:
/// `updates.rollback` (a kept build), `updates.builds` and `updates.switch_build` (any recent
/// nightly, `cmux nightly list|install`). Leo (2026-11-02): "idk if i should go without a way to
/// revert nightlies to an older version convieniently".
@MainActor
public struct UpdateBuildControl {
    public let updater: UpdaterService
    /// The daemons' state roots a rollback's store check reads (nil: cmux-tui's default).
    public let stateDirectories: @MainActor () -> [URL?]

    public init(updater: UpdaterService, stateDirectories: @escaping @MainActor () -> [URL?]) {
        self.updater = updater
        self.stateDirectories = stateDirectories
    }

    public var methods: [ControlMethod] {
        let updater = updater, stateDirectories = stateDirectories
        return [
            // `{build?, check?}`: rolls back to a kept build, or with check
            // only reports whether it would. Both daemons' stores count: the
            // app's and the Chief conversation owner's.
            .mainActor("updates.rollback") { call in
                let build = call.params["build"]?.stringValue
                let check = call.params["check"]?.boolValue == true
                let directories = stateDirectories()
                return .followUp {
                    do {
                        let kept = try await UpdateDropBack(updater).run(to: build, checkOnly: check, stateDirectories: directories)
                        return check ? .object(["allowed": true, "build": .string(kept.build)]) : .object(["rolled_back_to": .string(kept.build)])
                    } catch let refusal as RollbackRefusal {
                        if check { return .object(["allowed": false, "reason": .string(refusal.message)]) }
                        throw ControlError(code: "rollback_refused", message: refusal.message)
                    }
                }
            },
            // `{limit?}`: the nightly track's recent builds, newest first (`cmux nightly list`): each
            // with its date, commit, first change titles, and whether `updates.switch_build` takes it.
            // It reads the feed's notes, verdicts and pulled list, so it gets more than the 2 s deadline.
            .mainActor("updates.builds") { call in
                let limit = UpdaterService.recentBuildsLimit(call.params["limit"]?.doubleValue)
                return .followUp {
                    let builds = await updater.recentBuilds(limit: limit)
                    return await MainActor.run {
                        JSONValue.object(["installed": .string(updater.identity.build), "switches": .bool(updater.switchesBuilds),
                                          "builds": .array(builds.map(Self.json))])
                    }
                }
            }.withDeadline(.fixed(.seconds(30))),
            // `{build}`: installs that build, older or newer (`cmux nightly install`), the way the
            // Channels card's Switch does: download, signature and team check, keep, swap, and the build
            // left behind is no longer offered. The app quits and reopens into it; the answer may not
            // arrive. A refusal is `switch_refused` with what the person reads.
            .mainActor("updates.switch_build") { call in
                guard let build = call.params["build"]?.stringValue, !build.isEmpty else {
                    throw ControlError.invalidParams("updates.switch_build needs build")
                }
                return .followUp {
                    if let failure = await updater.switchToBuild(build) {
                        throw ControlError(code: "switch_refused", message: failure)
                    }
                    return .object(["switching_to": .string(build)])
                }
            }.withDeadline(.fixed(.seconds(600))),
        ]
    }

    nonisolated static func json(_ build: RecentBuild) -> JSONValue {
        .object([
            "build": .string(build.build), "version": .string(build.version), "date": .string(build.date),
            "commit": build.commit.map(JSONValue.string) ?? .null, "health": .string(build.health),
            "pulled_reason": build.pulledReason.map(JSONValue.string) ?? .null,
            "installed": .bool(build.installed), "kept": .bool(build.kept), "switchable": .bool(build.switchable),
            "titles": .array(build.titles.map(JSONValue.string)),
        ])
    }
}
