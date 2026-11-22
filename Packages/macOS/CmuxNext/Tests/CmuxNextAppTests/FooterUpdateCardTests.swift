import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater

/// UPDATE-CARD (Lawrence 2026-10-06; amends SIDEBAR-FOOTER-MINIMAL): only
/// while an update is staged, a card above the footer says "cmux <version>
/// is ready" with an Automatic Updates checkbox bound to
/// `updates.downloadAutomatically` and one Restart to Update button; its
/// popover lists the staged build's changes. One click installs and
/// relaunches with keep sessions, so no question shows. Before, the update
/// was an "Update Ready" pill with a one-line tooltip.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct FooterUpdateCardTests {
    @Test func theCardFollowsTheUpdateState() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        for phase: UpdateIndicatorPhase in [.hidden, .checking, .downloading(progress: 0.3), .available(version: "2")] {
            updater.debugIndicatorPhase = phase
            #expect(SidebarCardFeed.updateCard(updater) == nil, "\(phase) shows no update card")
        }
        updater.debugIndicatorPhase = .ready(version: "2")
        let card = try #require(SidebarCardFeed.updateCard(updater))
        #expect(card.title == UpdaterStrings.cardReady("2"))
        #expect(card.buttonTitle == UpdaterStrings.restartToUpdate && card.isEnabled)
        #expect(card.notes.keepsRunning == UpdaterStrings.keepsRunning)
        #expect(!SidebarCardFeed.cards(updater).contains { $0.id == SidebarCardFeed.updateCardID }, "never a stack card")
        updater.debugIndicatorPhase = .installing
        #expect(SidebarCardFeed.updateCard(updater)?.isEnabled == false)
        #expect(SidebarCardFeed.updateCard(updater)?.buttonTitle == UpdaterStrings.installing)
    }

    /// The window's sidebar shows the card once the updater stages an
    /// update, and hides it again after.
    @Test func theWindowSidebarShowsTheCardOnlyWhileStaged() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        let sidebar = harness.window.sidebar
        updater.debugIndicatorPhase = .ready(version: "2")
        for _ in 0..<200 where sidebar.model.updateCard == nil { await Task.yield() }
        #expect(sidebar.model.updateCard?.title == UpdaterStrings.cardReady("2"))
        updater.debugIndicatorPhase = .downloading(progress: 0.5)
        for _ in 0..<200 where sidebar.model.updateCard != nil { await Task.yield() }
        #expect(sidebar.model.updateCard == nil)
    }

    /// The popover's changes are the staged build's notes (the debug stage
    /// path's fake notes here): five newest, then "N more changes".
    @Test func thePopoverReadsTheStagedNotes() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        let sidebar = harness.window.sidebar
        updater.debugStage(version: "2.0.0", notes: DebugUpdater.fakeNotes(version: "2.0.0", changes: 12))
        for _ in 0..<200 where sidebar.model.updateCard?.notes.changes.isEmpty != false { await Task.yield() }
        let notes = try #require(sidebar.model.updateCard?.notes)
        #expect(notes.headline == UpdaterStrings.downloadedHeadline("2.0.0"))
        #expect(notes.changes.count == UpdateReadyNotes.shownChanges)
        #expect(notes.changes.first?.linkTitle == "#18000")
        #expect(notes.changes.first?.url == URL(string: "https://github.com/manaflow-ai/cmux/pull/18000"))
        #expect(notes.changes.first?.author != nil)
        #expect(notes.moreTitle == UpdaterStrings.moreChanges(7))
        updater.debugStage(version: nil, notes: nil)
        for _ in 0..<200 where sidebar.model.updateCard != nil { await Task.yield() }
        #expect(sidebar.model.updateCard == nil)
    }

    /// The checkbox is `updates.downloadAutomatically`: a click writes
    /// cmux.json, and a change of the setting updates the checkbox.
    @Test func theCheckboxIsBoundToTheSetting() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-update-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: harness.services.registry, design: DesignSettings(), fileURL: url)
        settings.start()
        defer { settings.stop() }
        let updater = harness.services.updater
        updater.follow(settings)
        defer { updater.settingsObservation?.cancel() }
        let sidebar = harness.window.sidebar
        updater.debugIndicatorPhase = .ready(version: "2")
        try await eventually { sidebar.model.updateCard?.automaticUpdates == true }

        sidebar.handle(.setAutomaticUpdates(false))
        try await eventually { settings.snapshot.updates.downloadAutomatically == false }
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Bool]]
        #expect(written?["updates"]?["downloadAutomatically"] == false)
        try await eventually { sidebar.model.updateCard?.automaticUpdates == false }

        try await settings.setSetting(at: UpdatesSettings.downloadAutomaticallyPath, to: .bool(true), by: .user)
        try await eventually { sidebar.model.updateCard?.automaticUpdates == true }
    }

    /// Waits (bounded) for settings writes and main-actor observation hops.
    private func eventually(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition(), "line \(line)")
    }

    /// The button's click installs the staged update at once (no dialog), and
    /// Sparkle's relaunch then quits keeping every session.
    @Test func aClickInstallsAndRelaunchesKeepingSessions() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        var presented = 0, installs = 0
        updater.presentUpdateUI = { presented += 1 }
        // What Sparkle does after reply(.install): its relaunch hook.
        updater.installStaged = {
            installs += 1
            updater.updaterWillRelaunchApplication()
        }
        updater.debugIndicatorPhase = .ready(version: "2")
        harness.window.sidebar.handle(.installUpdate)
        #expect(installs == 1)
        #expect(presented == 0)
        let origin = harness.services.quit.origins.consume()
        #expect(origin == .explicit(.keep))
        #expect(QuitPolicy.decide(origin, behavior: .ask, facts: .none) == .quit(.keep))
        // No unsaved edits: the quit's unsaved step shows nothing either.
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        #expect(await QuitUnsavedStep.resolve(origin, registry: QuitUnsavedRegistry(drafts: nil), scope: .app, center: center, writeDrafts: {}))
        #expect(center.records.isEmpty)
    }

    /// A Settings item's tooltip names Settings and its shortcut (the gear
    /// left the default footer with amendment 2; a user can add it back).
    @Test func theGearTooltipNamesSettingsAndItsShortcut() throws {
        let withGear = try SidebarLayoutReducer.reduce(.defaults, .itemAdd(LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings), showsLabel: false),
                                                                          section: SidebarLayoutDocument.bottomSectionID, index: 1)).get()
        let infos = SidebarBridge.itemInfo(for: withGear, registered: { _ in true },
                                           shortcut: { $0 == "openSettings" ? "⌘," : nil })
        let settings = infos[LayoutItemID("itm_settings")]
        #expect(settings?.shortcut == "⌘,")
        #expect(settings?.toolTip.contains(SectionStrings.settings) == true)
        #expect(settings?.toolTip.contains("⌘,") == true)
        #expect(infos[LayoutItemID("itm_account")]?.shortcut == nil)
    }
}
