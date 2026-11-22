import AppKit
import CmuxNextActions
@testable import CmuxNextCloudUI
import CmuxNextDesign
import Testing

/// The sidebar's Team section is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): it builds no
/// `NSHostingView`, draws a row per session of the picked filter, and its eye and its click run
/// what the section was made with.
@MainActor @Suite struct CloudTeamSectionViewTests {
    typealias Fixture = CloudTeamSessionStoreTests

    /// What the section's closures were asked to run.
    @MainActor final class Recorder {
        var performed: [(id: ActionID, arguments: [String: ActionValue])] = []
        var opened: [String] = []
    }

    /// A section over `rows` under the Team filter, as the store lists them.
    static func section(_ rows: [[String: Any]], _ recorder: Recorder) async -> CloudTeamHostingView {
        let worker = Fixture.FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport, activeTeam: { Fixture.team })
        // The select's list, and the section's own first list should it run before the test reads the rows.
        worker.replies = Array(repeating: .success(Fixture.list(rows)), count: 4)
        await store.select(.team)
        return CloudTeamHostingView(store: store, tokens: { ThemeScope.app.tokens },
                                    perform: { id, arguments in recorder.performed.append((id, arguments)) },
                                    open: { row in recorder.opened.append(row.session) })
    }

    static func views(under view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + views(under: $0) }
    }

    @Test func theSectionIsAppKitWithARowPerSession() async {
        let view = await Self.section([Fixture.row("s1", at: 5), Fixture.row("s2", at: 4, mine: true)], Recorder())
        #expect(Self.views(under: view).allSatisfy { !String(describing: type(of: $0)).contains("NSHostingView") })
        #expect(view.section.rows.map(\.titleText) == ["Chat s1", "Chat s2"])
        #expect(view.section.rows.map(\.showsFollow) == [true, false], "a session assigned to the person has no follow toggle")
        #expect(view.section.placeholderText == nil)
        #expect(view.section.filters.filter(\.isSelected).map(\.title) == [CloudTeamStrings.filterTitle(.team)])
        #expect(view.preferredHeight == CloudTeamSectionView.filterHeight + CloudTeamSectionView.rowHeight * 2)
    }

    @Test func theEyeFollowsAndAClickOpensTheSession() async throws {
        let recorder = Recorder()
        let view = await Self.section([Fixture.row("s1")], recorder)
        let row = try #require(view.section.rows.first)
        row.toggleFollow()
        #expect(recorder.performed.map(\.id) == ["cloud.team.follow"])
        #expect(recorder.performed.first?.arguments["session"]?.stringValue == "cloud:\(Fixture.team)/vm_a/s1")
        view.frame = NSRect(x: 0, y: 0, width: 240, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        let point = row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        row.mouseUp(with: click)
        #expect(recorder.opened == ["s1"])
    }

    @Test func noSessionsShowTheFiltersEmptyText() async {
        let view = await Self.section([], Recorder())
        #expect(view.section.rows.isEmpty)
        #expect(view.section.placeholderText == CloudTeamStrings.empty(.team))
    }
}
