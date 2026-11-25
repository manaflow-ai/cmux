public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Updates' App Update card: Go Back to Previous Build. Leo (2026-11-21): "we ought to
/// have good recovery and bisecting either automatically or agents being able to just say "actually
/// let's go back to this other version :)" and/or the user should be able to easily access it too".
/// The card names the newest build this Mac kept (its number, day and commit) and whether the one
/// drop-back path (``UpdateDropBack``) would take it, read on demand when the card shows
/// (`cmux.settings.app_update.previous`); its button takes that same path
/// (`cmux.settings.app_update.rollback`), so a refusal reads the same everywhere.
extension UpdaterService {
    /// The card's row: null when this Mac kept no build, else the build, its texts and `refusal`
    /// (``RollbackRefusal/message``, null when the rollback would run).
    public func previousBuildPageJSON() async -> JSONValue {
        let store = keptVersions
        let listed = try? await work.run(.userVisible, mayBlock: .files) { store.list() }
        guard let kept = listed?.first else { return .null }
        let refusal: String?
        do {
            _ = try await UpdateDropBack(self).run(to: kept.build, checkOnly: true, stateDirectories: pulledWatch.stateDirectories())
            refusal = nil
        } catch let refused as RollbackRefusal {
            refusal = refused.message
        } catch {
            refusal = UpdateFailureText.plain(error)
        }
        // The day and commit the feed's notes give (the verified cache offline), else the bundle's own commit.
        let entry = await changelogNotes?.index().first { $0.build == kept.build }
        return Self.previousBuildJSON(kept, date: entry?.date, commit: entry?.head ?? kept.commit, refusal: refusal)
    }

    nonisolated static func previousBuildJSON(_ kept: KeptVersion, date: String?, commit: String?, refusal: String?) -> JSONValue {
        let named = ChannelBuild(build: kept.build, shortVersion: kept.shortVersion, date: date ?? "", commit: commit)
        return .object([
            "build": .string(kept.build),
            "version": .string(kept.shortVersion),
            "date": date.map(JSONValue.string) ?? .null,
            "commit": commit.map { .string(String($0.prefix(8))) } ?? .null,
            "commit_url": named.commitURL.map { .string($0.absoluteString) } ?? .null,
            "title": .string(UpdaterStrings.previousBuildTitle),
            "action": .string(UpdaterStrings.previousBuildAction),
            "detail": .string(UpdaterStrings.channelsGoBackDetail(kept.shortVersion)),
            "build_label": .string(UpdaterStrings.previousBuildLabel(kept.build)),
            "refusal": refusal.map(JSONValue.string) ?? .null,
        ])
    }

    /// The card's Go Back to Previous Build: restarts into `build` when it is still the newest
    /// kept one. Nil when it runs (the app quits), else what the person reads.
    public func goBackToPreviousBuild(_ build: String) async -> String? {
        let store = keptVersions
        let newest = (try? await work.run(.userVisible, mayBlock: .files) { store.list() })?.first?.build
        guard newest == build else { return UpdaterStrings.previousBuildGone }
        log.append("settings: going back to kept build \(build)")
        return await UpdateDropBack(self).failure(to: build, stateDirectories: pulledWatch.stateDirectories())
    }
}

nonisolated extension UpdaterStrings {
    static var previousBuildTitle: String { text("updater.previous.title", "Go Back to Previous Build") }
    static var previousBuildAction: String { text("updater.previous.action", "Go Back") }
    static func previousBuildLabel(_ build: String) -> String { format("updater.previous.build", "Build %@", build) }
    static var previousBuildGone: String {
        text("updater.previous.gone", "That build is no longer the previous one. Reopen Settings to see the build kept now.")
    }
}
