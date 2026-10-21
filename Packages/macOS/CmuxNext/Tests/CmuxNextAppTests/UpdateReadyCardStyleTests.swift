import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextUpdater
import CmuxNextWakeups
import Foundation
import Testing

/// The Update Ready card's look and preview (Leo 2026-10-20): Automatic Updates is a themed
/// switch at the end of its row (Debug Settings brings the checkbox back), Restart to Update is
/// the app's primary button, a click on the card pins its changelog preview open and taller, and
/// Debug Settings "Simulate pending update" shows the newest published notes.
@MainActor @Suite(.serialized) struct UpdateReadyCardStyleTests {
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        var contentHeight: CGFloat = 2000
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
    }

    func make() async throws -> (card: SidebarUpdateCardView, window: NSWindow, sidebar: SidebarView) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = try DebugUpdater.run(["action": .string("stage"), "version": .string("1.0.0-nightly.3845050428001"),
                                  "changes": JSONValue(3)], services, terminate: {})
        let model = SidebarModel()
        model.updateCard = SidebarCardFeed.updateCard(services.updater)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: Metrics.sidebarWidth, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 640)
        let deadline = ContinuousClock.now + .seconds(10)
        while sidebar.updateCardView.isHidden || sidebar.updateCardView.card == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        return (sidebar.updateCardView, window, sidebar)
    }

    @Test func aClickPinsThePreviewOpenAndTallerUntilTheNextClick() async throws {
        let (card, window, _) = try await make()
        defer {
            card.hideNotes()
            window.close()
        }
        try #require(!card.isHidden, "the staged update shows no card")
        window.orderFront(nil)
        card.highlights = Highlights()
        card.notesCloseTimer = DemandTimer(owner: "test.update-card.pin", clock: ManualClock())
        let resting = card.notesHeight(for: 2000)
        card.toggleNotesPinned()
        #expect(card.notesPinned)
        #expect(card.notesAreShown, "a click on the card opened no preview")
        #expect(card.notesHeight(for: 2000) > resting, "the pinned preview is no taller than the hover one")
        // The pointer goes far away: a pinned preview schedules no close and a stray check keeps it.
        card.screenPointer = { CGPoint(x: -50_000, y: -50_000) }
        card.pointerLeftNotes()
        #expect(!card.notesCloseTimer.isScheduled, "a pinned preview scheduled a close")
        card.notesCloseFired()
        #expect(card.notesAreShown, "a pinned preview closed when the pointer left")
        card.toggleNotesPinned()
        #expect(!card.notesPinned)
        #expect(await eventually { !card.notesAreShown }, "the second click left the preview open")
    }

    @Test func automaticUpdatesIsAThemedSwitchAtTheEndOfItsRow() throws {
        #expect(SidebarTunables.updateCardAutomaticControl.defaultValue == .switchControl)
        let control = SidebarUpdateCheckbox(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateCheckbox.height))
        control.configure(title: "Automatic Updates", isOn: true)
        control.layoutSubtreeIfNeeded()
        control.updateLayer()
        let track = try #require(control.layer?.sublayers?.first)
        let knob = try #require(control.layer?.sublayers?.dropFirst().first)
        #expect(track.frame.maxX == control.bounds.maxX, "the switch is not at the end of the row")
        #expect(track.backgroundColor == control.performWithTheme { Palette.accentFill.cgColor })
        #expect(knob.frame.midX > track.frame.midX, "an on switch has its knob at the leading end")
        #expect(control.accessibilitySubrole() == .switch)
        control.configure(title: "Automatic Updates", isOn: false)
        control.layoutSubtreeIfNeeded()
        #expect(knob.frame.midX < track.frame.midX, "an off switch has its knob at the trailing end")
        // Debug Settings' checkbox: the box in front of the label, as before.
        control.fixedLook = .checkbox
        control.configure(title: "Automatic Updates", isOn: true)
        control.layoutSubtreeIfNeeded()
        #expect(track.frame.minX == 0)
        #expect(knob.isHidden)
    }

    @Test func restartToUpdateIsThePrimaryButton() {
        #expect(SidebarTunables.updateCardButton.defaultValue == .primary)
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateButton.height))
        button.fixedStyle = .primary
        button.configure(title: "Restart to Update", enabled: true, help: nil)
        button.updateLayer()
        #expect(button.layer?.backgroundColor == button.performWithTheme { Palette.accentFill.cgColor })
        #expect(button.layer?.borderWidth == 0, "the primary button draws the bordered button's hairline")
    }

    @Test func theSimulationShowsTheNewestPublishedNotesWithHighlights() {
        let index = [
            ReleaseNotesIndexEntry(build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-18", highlights: 2),
            ReleaseNotesIndexEntry(build: "102", shortVersion: "1.0.0-nightly.102", date: "2026-10-20", highlights: 0),
            ReleaseNotesIndexEntry(build: "101", shortVersion: "1.0.0-nightly.101", date: "2026-10-19", highlights: 1),
        ]
        #expect(DebugUpdater.simulatedBuild(from: index) == "101")
        #expect(DebugUpdater.simulatedBuild(from: index.map { var e = $0; e.highlights = 0; return e }) == "102")
        #expect(DebugUpdater.simulatedBuild(from: []) == nil)
        #expect(SidebarTunables.simulatePendingUpdate.defaultValue == false)
    }

    func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
