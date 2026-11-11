public import CmuxNextSettings
public import Foundation

/// Going back from the Updated card's changes (the React surface beside the sidebar): its footer's
/// "Go back to <version> from <date>" and the list of recent builds under it. The App's
/// `UpdateSurfaceProvider` hands it the `cmux.changelog.surface.goBack` and `.builds` ops, so the
/// App grows by no logic. Leo (2026-11-11) asked for a faster, more reliable way back to the
/// previous nightly, with a better UI.
@MainActor
public struct UpdateRevertSurface {
    public let updater: UpdaterService

    public init(_ updater: UpdaterService) {
        self.updater = updater
    }

    /// The answer to `op`, or nil for an op this does not own.
    /// - `cmux.changelog.surface.goBack {build?}`: goes back (no build: the previous one, kept or
    ///   downloaded); answers `{failure}` when it does not run (the app quits when it does).
    /// - `cmux.changelog.surface.builds {limit?}`: the recent builds, newest first, each with its
    ///   date, its first change titles, and whether going to it needs a download.
    public func call(_ op: String, params: JSONValue) async -> JSONValue? {
        switch op {
        case "cmux.changelog.surface.goBack":
            let build = params["build"]?.stringValue
            let failure = await UpdateDropBack(updater).failure(to: build, stateDirectories: updater.pulledWatch.stateDirectories())
            return .object(["failure": failure.map(JSONValue.string) ?? .null])
        case "cmux.changelog.surface.builds":
            let limit = UpdaterService.recentBuildsLimit(params["limit"]?.doubleValue ?? 6)
            let builds = await updater.recentBuilds(limit: limit)
            return .object(["installed": .string(updater.identity.build), "builds": .array(builds.map(Self.json))])
        default:
            return nil
        }
    }

    nonisolated static func json(_ build: RecentBuild) -> JSONValue {
        .object([
            "build": .string(build.build), "version": .string(build.version), "date": .string(build.date),
            "installed": .bool(build.installed), "kept": .bool(build.kept), "switchable": .bool(build.switchable),
            "pulled": .bool(build.health == "pulled"), "titles": .array(build.titles.map(JSONValue.string)),
        ])
    }
}

extension UpdaterService {
    /// The Updated card's way back, in its highlights (`goBack`): the build and its words, nil
    /// with nothing kept to go back to (the card then offers the list only).
    var goBackJSON: JSONValue {
        guard let offer = revertOffer else { return .null }
        return .object(["build": .string(offer.build), "label": .string(offer.label), "kept": .bool(offer.kept),
                        "title": .string(UpdaterStrings.goBackTitle(offer.label))])
    }
}
