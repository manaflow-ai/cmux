import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import CmuxNextWakeups
import Foundation
import Testing
import CmuxNextWakeupsTestSupport
import CmuxNextTestSupport

/// The Update Ready card's look and preview (Leo 2026-10-20): Automatic Updates is a themed
/// switch in front of its label (Debug Settings brings the checkbox back), Restart to Update is
/// the app's primary button, a click on the card pins its changelog preview open and taller, and
/// Debug Settings "Simulate pending update" shows the newest published notes, even on the newest build.
@MainActor @Suite(.closesItsWindows, .serialized) struct UpdateReadyCardStyleTests {
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
            let popup = card.hoverCards()?.cardWindow
            card.hideNotes()
            window.close()
            popup?.closeAfterTest()
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

    @Test func automaticUpdatesIsAThemedSwitchInFrontOfItsLabel() throws {
        #expect(SidebarTunables.updateCardAutomaticControl.defaultValue == .switchControl)
        let control = SidebarUpdateToggle(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateToggle.height))
        control.configure(title: "Automatic Updates", isOn: true)
        control.layoutSubtreeIfNeeded()
        control.updateLayer()
        let track = try #require(control.layer?.sublayers?.first)
        let knob = try #require(control.layer?.sublayers?.dropFirst().first)
        // The switch on the left, then the label (Leo 2026-10-22: "he preferred the checkbox on the left").
        #expect(track.frame.minX == 0, "the switch is not at the start of the row")
        #expect(control.label.frame.minX >= track.frame.maxX + Metrics.space2, "the label is not after the switch")
        #expect(track.backgroundColor == control.performWithTheme { Palette.accentFill.cgColor })
        #expect(knob.frame.midX > track.frame.midX, "an on switch has its knob at the leading end")
        #expect(control.accessibilitySubrole() == .switch)
        // The switch's centre is on the label's cap-height midline (2026-10-22), not the row box's centre.
        let capMid = control.label.frame.minY + control.label.firstBaselineOffsetFromTop - SidebarUpdateToggle.font.capHeight / 2
        #expect(abs(track.frame.midY - capMid) <= 0.5, "the switch sits off its label's centre line")
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

    /// The card's first configure (Automatic Updates on, the control fresh at off) puts the knob
    /// in place: it never slides in from the row's corner.
    @Test func theSwitchSlidesOnlyOnceLaidOutAndShown() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let control = SidebarUpdateToggle(frame: .zero)
        control.fixedLook = .switchControl
        window.contentView?.addSubview(control)
        #expect(!control.canSlide, "a switch with no laid-out track would slide in from the corner")
        control.configure(title: "Automatic Updates", isOn: true)
        let knob = control.layer?.sublayers?.dropFirst().first
        #expect(knob?.animationKeys() == nil, "the first configure animated the knob")
        control.frame = NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateToggle.height)
        control.layoutSubtreeIfNeeded()
        #expect(control.canSlide)
        control.isHidden = true
        #expect(!control.canSlide, "a hidden switch slides")
    }

    /// Installing… (disabled) is dimmer than Restart to Update, in the accent and in the neutral
    /// primary: fading the translucent neutral fill to a fixed alpha made it about 4x as opaque.
    @Test func aDisabledPrimaryButtonIsDimmerThanAnEnabledOne() {
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateButton.height))
        button.fixedStyle = .primary
        button.configure(title: "Restart to Update", enabled: true, help: nil)
        let enabled = button.fill.alphaComponent
        button.configure(title: "Installing…", enabled: false, help: nil)
        let disabled = button.fill.alphaComponent
        #expect(disabled < enabled, "the disabled button (alpha \(disabled)) is not dimmer than the enabled one (\(enabled))")
    }

    @Test func restartToUpdateIsThePrimaryButton() {
        #expect(SidebarTunables.updateCardButton.defaultValue == .primary)
        let button = SidebarUpdateButton(frame: NSRect(x: 0, y: 0, width: 180, height: SidebarUpdateButton.height))
        button.fixedStyle = .primary
        button.configure(title: "Restart to Update", enabled: true, help: nil)
        button.updateLayer()
        // The theme's accent when one is chosen; with none, the prominent neutral, never the
        // primary text as a white slab (2026-10-22: "just make it look better").
        let (chosen, accent, neutral, slab) = button.performWithTheme {
            (Palette.hasChosenAccent, Palette.accentFill.cgColor, Palette.selectionFill.cgColor, Palette.textPrimary.cgColor)
        }
        #expect(button.layer?.backgroundColor == (chosen ? accent : neutral))
        if !chosen { #expect(button.layer?.backgroundColor != slab, "Restart to Update is the white slab again") }
        #expect(button.layer?.borderWidth == 0, "the primary button draws the bordered button's hairline")
    }

    @Test func theSimulationShowsTheNewestPublishedNotesWithHighlights() {
        let index = [
            ReleaseNotesIndexEntry(build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-18", highlights: 2),
            ReleaseNotesIndexEntry(build: "102", shortVersion: "1.0.0-nightly.102", date: "2026-10-20", highlights: 0),
            ReleaseNotesIndexEntry(build: "101", shortVersion: "1.0.0-nightly.101", date: "2026-10-19", highlights: 1),
        ]
        #expect(UpdateSimulation.build(from: index) == "101")
        #expect(UpdateSimulation.build(from: index.map { var e = $0; e.highlights = 0; return e }) == "102")
        #expect(UpdateSimulation.build(from: []) == nil)
        // Builds of one day order by number, not as text ("99" sorts after "100").
        let sameDay = [
            ReleaseNotesIndexEntry(build: "99", shortVersion: "1.0.0-nightly.99", date: "2026-10-20", highlights: 1),
            ReleaseNotesIndexEntry(build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-20", highlights: 1),
        ]
        #expect(UpdateSimulation.build(from: sameDay) == "100")
        #expect(SidebarTunables.simulatePendingUpdate.defaultValue == false)
    }

    /// On the newest nightly the newest published notes are the running build's own. Staged under
    /// that version, the gate that never offers the running build hid the card (#22804): the
    /// simulation stages a pretend newer version and keeps the real notes.
    @Test func theSimulationShowsTheCardOnTheNewestBuild() throws {
        let updater = Self.updater(shortVersion: "1.0.0-nightly.100", build: "100")
        let simulation = UpdateSimulation(updater: updater)
        let own = ReleaseNotes(version: 1, build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-20", highlights: [],
                               changes: ["A real change"])
        let version = try #require(simulation.stage(with: own))
        #expect(version != updater.identity.shortVersion, "the simulation staged the running version")
        #expect(updater.readyCard != nil, "the simulation on the newest build shows no card")
        #expect(updater.stagedNotes == own, "the simulation dropped the real notes")
        // Notes of a newer build keep their own version; an older one's never reads as an update to it.
        let newer = ReleaseNotes(version: 1, build: "101", shortVersion: "1.0.0-nightly.101", date: "2026-10-21", highlights: [],
                                 changes: [])
        #expect(simulation.stage(with: newer) == "1.0.0-nightly.101")
        let older = ReleaseNotes(version: 1, build: "99", shortVersion: "1.0.0-nightly.99", date: "2026-10-19", highlights: [],
                                 changes: [])
        #expect(simulation.stage(with: older) == UpdateSimulation.sampleVersion)
        // Offline with nothing cached: the sample notes, still a card.
        #expect(simulation.stage(with: nil) == UpdateSimulation.sampleVersion)
        #expect(updater.readyCard != nil)
        simulation.end()
        #expect(updater.readyCard == nil, "turning the simulation off left the card")
    }

    /// An updater for a running app at `shortVersion` (`build`) with no Sparkle and nothing staged.
    static func updater(shortVersion: String, build: String) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-ready-card-style", shortVersion: shortVersion,
                                           build: build, minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdateReadyCardStyleTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.start()
        return updater
    }

    func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
