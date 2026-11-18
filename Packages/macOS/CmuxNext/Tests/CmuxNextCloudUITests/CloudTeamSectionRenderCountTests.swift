import AppKit
@testable import CmuxNextCloudUI
import CmuxVisibleRows
import Testing

/// The Team section draws what is in view: row views alive stay at the visible rows plus one viewport each
/// side at 100 sessions as at 10,000, and a change configures only the rows whose session changed.
@MainActor @Suite struct CloudTeamSectionRenderCountTests {
    typealias Fixture = CloudTeamSessionStoreTests

    /// The most row views a section may hold: its visible rows and one viewport past each edge, and one cut by an edge.
    static let bound = CloudTeamSectionView.maxRows * 3 + 1

    static func sessions(_ count: Int, prefix: String = "s") -> [CloudTeamSession] {
        (0..<count).compactMap { CloudTeamSession(Fixture.row("\(prefix)\($0)", at: count - $0)) }
    }

    /// A section laid out at its full height, showing `count` sessions under the Team filter; its work so far taken.
    static func section(_ count: Int) async -> (CloudTeamHostingView, CloudTeamSectionView.Shown) {
        let view = await CloudTeamSectionViewTests.section([], CloudTeamSectionViewTests.Recorder())
        let shown = CloudTeamSectionView.Shown(filter: .team, sessions: sessions(count), members: [], placeholder: "")
        view.section.apply(shown)
        view.frame = NSRect(x: 0, y: 0, width: 240,
                            height: CloudTeamSectionView.filterHeight + CloudTeamSectionView.rowHeight * CGFloat(CloudTeamSectionView.maxRows))
        view.layoutSubtreeIfNeeded()
        _ = view.section.listWork.take()
        return (view, shown)
    }

    @Test(arguments: [100, 10_000])
    func rowsAliveStayAtTheViewportAndOverscan(count: Int) async {
        let (view, _) = await Self.section(count)
        let section = view.section
        print("cloud-team-counts n=\(count) rows_alive=\(section.rowViewsAlive)")
        #expect(section.rowViewsAlive <= Self.bound)
        #expect(section.rows.map(\.titleText) == Array(Self.sessions(count).prefix(section.rows.count).map(\.title)),
                "the made rows are the top ones, in order")
    }

    @Test(arguments: [100, 10_000])
    func oneChangedSessionConfiguresOneRow(count: Int) async {
        var (view, shown) = await Self.section(count)
        let section = view.section
        shown.sessions[3].title = "Renamed"
        section.apply(shown)
        view.layoutSubtreeIfNeeded()
        let work = section.listWork.take()
        print("cloud-team-counts n=\(count) one_change=\(work)")
        #expect(work.rowsConfigured == 1)
        #expect(work.rowsLaidOut == 0)
        #expect(section.rows[3].titleText == "Renamed")
    }

    @Test(arguments: [100, 10_000])
    func theSameRowsOrNewMembersConfigureNone(count: Int) async {
        var (view, shown) = await Self.section(count)
        let section = view.section
        section.apply(shown)
        shown.members = [CloudTeamMember(user: "user_c", name: "Cy", role: "member")]
        section.apply(shown)
        view.layoutSubtreeIfNeeded()
        let work = section.listWork.take()
        print("cloud-team-counts n=\(count) same_rows_and_members=\(work)")
        #expect(work.rowsConfigured == 0)
        #expect(section.rows.allSatisfy { $0.members == shown.members }, "the rows' Reassign To offers the new members")
    }

    @Test(arguments: [100, 10_000])
    func anInsertAtTheTopConfiguresTheNewRowOnly(count: Int) async {
        var (view, shown) = await Self.section(count)
        let section = view.section
        let new = Self.sessions(1, prefix: "new")
        shown.sessions.insert(contentsOf: new, at: 0)
        section.apply(shown)
        view.layoutSubtreeIfNeeded()
        let work = section.listWork.take()
        print("cloud-team-counts n=\(count) top_insert=\(work)")
        #expect(work.rowsConfigured == 1)
        #expect(section.rows.first?.titleText == new.first?.title)
        #expect(section.rows.map(\.titleText) == Array(shown.sessions.prefix(section.rows.count).map(\.title)))
    }
}
