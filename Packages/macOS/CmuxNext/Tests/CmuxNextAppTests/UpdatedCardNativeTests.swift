import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextUpdater
import Testing

/// Lawrence 2026-12: the "Updated to Nightly" card and its hover notes are native again (no React in small
/// things like popovers). Leo: the React card's CSS glass never lined up with the Swift glass under it; the
/// native card paints none, so the host's one glass is its glass, at rest too.
@MainActor
@Suite(.serialized)
struct UpdatedCardNativeTests {
    static func highlights() -> UpdateHighlights {
        UpdateHighlights(version: "1.0.0-nightly.200", build: "200", fromVersion: "1.0.0-nightly.100", fromBuild: "100",
                         notes: ReleaseNotes.debugFake(version: "1.0.0-nightly.200", changes: 7), appcast: nil)
    }

    @Test func theSurfacesForTheUpdatedCardAndItsNotesAreNative() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let surfaces = UpdateSurfaceIslands(services: services)
        let card = surfaces.island(.updated), notes = surfaces.island(.updatedNotes)
        defer { card.close(); notes.close() }
        #expect(card is UpdatedCardIsland)
        #expect(notes is UpdatedNotesIsland)
        #expect(!card.paintsOwnGlass && !notes.paintsOwnGlass)
        #expect(card.contentSettled)
    }

    @Test func theCardSaysTheChannelAndTheTopChange() throws {
        let text = UpdatedCardText(Self.highlights(), background: false)
        #expect(text.name == "Nightly")
        #expect(text.headline.contains("Nightly"))
        #expect(!text.changes.isEmpty)
        let view = UpdatedCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
        view.text = text
        #expect(view.fittingHeight > 0)
        #expect(view.titleLineMid > 0 && view.titleLineMid < view.fittingHeight / 2)
    }

    @Test func theNotesListTheTopChangesAndSayHowManyMore() throws {
        let text = UpdatedCardText(Self.highlights(), background: false)
        let notes = UpdatedNotesView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        notes.text = text
        #expect(notes.subviews.compactMap { $0 as? UpdatedNotesRow }.count == min(text.changes.count, UpdateHighlights.shownItems))
        #expect((text.more(past: UpdateHighlights.shownItems) != nil) == (text.changes.count > UpdateHighlights.shownItems))
        #expect(notes.fittingHeight(width: 300) > 0)
    }

    /// The resting native card shows the host's glass (the composer's, ``SidebarUpdatedCardHost/glass``) as
    /// its own, the same frame: one glass, so its edge is the Swift glass's edge.
    @Test func aNativeCardRestsOnTheHostsGlass() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let card = SidebarUpdatedCard(title: "Updated", whatsNewTitle: "What's New", dismissLabel: "Close")
        let model = SidebarModel(sections: [])
        model.updatedCard = card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.updateSurfaces = UpdateSurfaceIslands(services: services)
        let host = sidebar.updatedCardView
        host.configure(card)
        defer { host.configure(nil) }
        let island = try #require(host.island as? UpdatedCardIsland)
        #expect(!island.paintsOwnGlass)
        #expect(host.frosts(preview: 0), "a native card keeps the host's glass at rest")
    }

    @Test func aDropPastHalfTheRoomMovesTheCardToTheOtherEnd() {
        let rest = SidebarCardPlace(anchor: .bottom, above: 400, below: 0)
        #expect(UpdatedCardView.drop(offset: CGPoint(x: 0, y: -100), place: rest) == .bottom)
        #expect(UpdatedCardView.drop(offset: CGPoint(x: 0, y: -260), place: rest) == .top)
        let top = SidebarCardPlace(anchor: .top, above: 0, below: 400)
        #expect(UpdatedCardView.drop(offset: CGPoint(x: 0, y: 260), place: top) == .bottom)
    }
}
