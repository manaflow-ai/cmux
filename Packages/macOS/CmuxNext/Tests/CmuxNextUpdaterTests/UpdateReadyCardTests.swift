import Foundation
import Testing
@testable import CmuxNextUpdater

/// UPDATE-CARD (Lawrence 2026-10-06): a staged update is a card with "cmux
/// <version> is ready", an Automatic Updates checkbox and Restart to Update;
/// its hover popover lists the staged build's changes from the release
/// notes (title, author, PR link; newest first) and "N more changes".
/// Before, the update was an "Update Ready" pill with a one-line tooltip
/// and the notes had no author or PR.
@MainActor
@Suite struct UpdateReadyCardTests {
    private func notes(_ count: Int, structured: Bool = true) -> ReleaseNotes {
        let items = (0..<count).map { ReleaseNotes.ChangeItem(title: "Change \(count - $0)", author: "dev\($0)", pr: 500 - $0) }
        return ReleaseNotes(version: 1, build: "200", shortVersion: "2.0.0", date: "2026-10-06", highlights: [],
                            changes: items.map { "\($0.title) (#\($0.pr ?? 0))" }, items: structured ? items : nil)
    }

    @Test func aSubjectGivesItsTitleAndPullRequest() {
        let item = ReleaseNotes.ChangeItem(subject: "Add the update card (#17890)")
        #expect(item.title == "Add the update card")
        #expect(item.pr == 17890)
        #expect(item.author == nil)
        #expect(item.url == URL(string: "https://github.com/manaflow-ai/cmux/pull/17890"))
        #expect(item.prLabel == "#17890")
        let plain = ReleaseNotes.ChangeItem(subject: "Fix a crash (when idle)")
        #expect(plain.title == "Fix a crash (when idle)")
        #expect(plain.pr == nil && plain.url == nil)
    }

    /// Older notes (no `items`) still decode; their changes come from the
    /// subjects. New notes carry items with authors.
    @Test func notesWithoutItemsDecodeAndFallBackToSubjects() throws {
        let old = #"{"version":1,"build":"9","shortVersion":"1.0","date":"","highlights":[],"changes":["Faster tabs (#12)","Fix"]}"#
        let decoded = try JSONDecoder().decode(ReleaseNotes.self, from: Data(old.utf8))
        #expect(decoded.items == nil)
        #expect(decoded.changeItems == [ReleaseNotes.ChangeItem(title: "Faster tabs", pr: 12), ReleaseNotes.ChangeItem(title: "Fix")])
        let new = #"{"version":1,"build":"9","shortVersion":"1.0","date":"","highlights":[],"changes":["A (#3)"],"#
            + #""items":[{"title":"A","author":"ada","pr":3}]}"#
        let structured = try JSONDecoder().decode(ReleaseNotes.self, from: Data(new.utf8))
        #expect(structured.changeItems == [ReleaseNotes.ChangeItem(title: "A", author: "ada", pr: 3)])
    }

    /// The popover: the version line, the keep-running line, the five
    /// newest changes in the notes' order, and "7 more changes" linking to
    /// the full release notes.
    @Test func thePopoverListsTheNewestChangesAndCountsTheRest() throws {
        let link = try #require(URL(string: "https://github.com/manaflow-ai/cmux/releases/tag/v2.0.0"))
        let popover = UpdateReadyNotes(version: "2.0.0", notes: notes(12), fullNotesURL: link)
        #expect(popover.headline == "Update 2.0.0 downloaded. Click to restart and install.")
        #expect(popover.keepsRunning == "Your terminals and agents keep running.")
        #expect(popover.whatsChangedTitle == "What's changed")
        #expect(popover.changes.map(\.title) == ["Change 12", "Change 11", "Change 10", "Change 9", "Change 8"])
        #expect(popover.changes.first?.author == "dev0")
        #expect(popover.changes.first?.url == URL(string: "https://github.com/manaflow-ai/cmux/pull/500"))
        #expect(popover.moreCount == 7)
        #expect(popover.moreTitle == "7 more changes")
        #expect(popover.moreURL == link)
        // Subject-only notes give the same list without authors.
        let fallback = UpdateReadyNotes(version: "2.0.0", notes: notes(12, structured: false), fullNotesURL: link)
        #expect(fallback.changes.map(\.title) == popover.changes.map(\.title))
        #expect(fallback.changes.allSatisfy { $0.author == nil && $0.pr != nil })
    }

    @Test func fewChangesShowNoMoreLineAndNoNotesShowOnlyTheLink() throws {
        let link = try #require(URL(string: "https://github.com/manaflow-ai/cmux/releases"))
        let few = UpdateReadyNotes(version: "2.0.0", notes: notes(3), fullNotesURL: link)
        #expect(few.changes.count == 3 && few.moreCount == 0 && few.moreTitle == nil)
        #expect(UpdateReadyNotes(version: "2.0.0", notes: notes(6), fullNotesURL: link).moreTitle == "1 more change")
        let none = UpdateReadyNotes(version: nil, notes: nil, fullNotesURL: link)
        #expect(none.headline == "Update downloaded. Click to restart and install.")
        #expect(none.whatsChangedTitle == nil && none.changes.isEmpty)
        #expect(none.moreTitle == UpdaterStrings.releaseNotes && none.moreURL == link)
    }

    @Test func theCardNamesTheVersionAndInstallingDisablesTheButton() {
        let notes = UpdateReadyNotes(version: "2.0.0", notes: nil, fullNotesURL: nil)
        let ready = UpdateReadyCard(version: "2.0.0", isInstalling: false, automaticUpdates: true, notes: notes)
        #expect(ready.title == "cmux 2.0.0 is ready")
        #expect(ready.buttonTitle == "Restart to Update")
        #expect(ready.automaticUpdatesTitle == "Automatic Updates")
        let installing = UpdateReadyCard(version: "2.0.0", isInstalling: true, automaticUpdates: true, notes: notes)
        #expect(installing.buttonTitle == UpdaterStrings.installing && installing.isInstalling)
    }

    /// The service: no card without a staged update; a staged update loads
    /// its build's notes once (when staged), and reading the card again
    /// (every hover) never loads again. Installing keeps the card, disabled.
    @Test func aStagedUpdateLoadsItsNotesOnceAndTheCardReadsThem() async throws {
        let defaults = try #require(UserDefaults(suiteName: "update-ready-card-\(UUID().uuidString)"))
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        let loads = LoadCounter()
        let staged = notes(8)
        service.notesLoader = { build in
            await loads.add(build)
            return staged
        }
        service.stagedBuild = { "200" }
        #expect(service.readyCard == nil)
        service.debugIndicatorPhase = .downloading(progress: 0.5)
        #expect(service.readyCard == nil, "downloading shows no card")
        service.debugIndicatorPhase = .ready(version: "2.0.0")
        for _ in 0..<200 where service.stagedNotes == nil { await Task.yield() }
        let card = try #require(service.readyCard)
        #expect(card.title == "cmux 2.0.0 is ready")
        #expect(card.notes.changes.count == UpdateReadyNotes.shownChanges)
        #expect(card.notes.moreTitle == "3 more changes")
        for _ in 0..<5 { _ = service.readyCard }
        #expect(await loads.builds == ["200"], "notes load once, when staged")
        service.debugIndicatorPhase = .installing
        #expect(service.readyCard?.isInstalling == true)
        #expect(service.readyCard?.title == "cmux 2.0.0 is ready", "the version stays while it installs")
        service.debugIndicatorPhase = .hidden
        #expect(service.readyCard == nil && service.stagedNotes == nil)
    }

    /// The checkbox shows `updates.downloadAutomatically` and writes it
    /// through the App's settings path.
    @Test func theCheckboxFollowsAndWritesTheSetting() {
        let defaults = UserDefaults(suiteName: "update-ready-box-\(UUID().uuidString)") ?? .standard
        let service = UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100"),
                                     policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false)
        var writes: [Bool] = []
        service.writeAutomaticUpdates = { writes.append($0) }
        service.debugIndicatorPhase = .ready(version: "2")
        #expect(service.readyCard?.automaticUpdates == true)
        service.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: false)
        #expect(service.readyCard?.automaticUpdates == false)
        service.setAutomaticUpdates(true)
        #expect(writes == [true])
    }
}

private actor LoadCounter {
    var builds: [String] = []
    func add(_ build: String) { builds.append(build) }
}
