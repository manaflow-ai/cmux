import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater

/// SIDEBAR-FOOTER-MINIMAL (Lawrence 2026-10-06): the footer is the avatar,
/// the gear and, only while an update is staged, an "Update Ready" pill.
/// One click on the pill installs and relaunches with keep sessions, so no
/// question shows; before, the update was an accent arrow on a Settings
/// text row (and, in older builds, an orange card).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct FooterUpdatePillTests {
    @Test func thePillFollowsTheUpdateState() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        for phase: UpdateIndicatorPhase in [.hidden, .checking, .downloading(progress: 0.3), .available(version: "2")] {
            updater.debugIndicatorPhase = phase
            #expect(SidebarCardFeed.updatePill(updater) == nil, "\(phase) shows nothing in the footer")
        }
        updater.debugIndicatorPhase = .ready(version: "2")
        #expect(SidebarCardFeed.updatePill(updater)
            == SidebarUpdatePill(title: UpdaterStrings.readyToInstall, help: UpdaterStrings.restartKeepsSessions, isEnabled: true))
        #expect(!SidebarCardFeed.cards(updater).contains { $0.id == SidebarCardFeed.updateCardID }, "never a card")
        updater.debugIndicatorPhase = .installing
        #expect(SidebarCardFeed.updatePill(updater)?.isEnabled == false)
        #expect(!SidebarCardFeed.cards(updater).contains { $0.id == SidebarCardFeed.updateCardID }, "installing is no card either")
    }

    /// The window's sidebar shows the pill once the updater stages an
    /// update, and hides it again after.
    @Test func theWindowSidebarShowsThePillOnlyWhileStaged() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let updater = harness.services.updater
        let sidebar = harness.window.sidebar
        updater.debugIndicatorPhase = .ready(version: "2")
        for _ in 0..<200 where sidebar.model.updatePill == nil { await Task.yield() }
        #expect(sidebar.model.updatePill?.title == UpdaterStrings.readyToInstall)
        updater.debugIndicatorPhase = .downloading(progress: 0.5)
        for _ in 0..<200 where sidebar.model.updatePill != nil { await Task.yield() }
        #expect(sidebar.model.updatePill == nil)
    }

    /// The pill's click installs the staged update at once (no dialog), and
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

    /// The gear's tooltip names Settings and its shortcut.
    @Test func theGearTooltipNamesSettingsAndItsShortcut() {
        let infos = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true },
                                           shortcut: { $0 == "openSettings" ? "⌘," : nil })
        let settings = infos[LayoutItemID("itm_settings")]
        #expect(settings?.shortcut == "⌘,")
        #expect(settings?.toolTip.contains(SectionStrings.settings) == true)
        #expect(settings?.toolTip.contains("⌘,") == true)
        #expect(infos[LayoutItemID("itm_account")]?.shortcut == nil)
    }
}
