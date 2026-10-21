@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21 (sidebar organization, item A): a workspace's hover card says what its agents
/// did since the person last looked at it ("Since you looked: Done: 2 · Asked: 1"), counted from
/// its history after the moment the selection left it.
@MainActor @Suite(.serialized) struct SidebarSinceLookedTests {
    private static let a = WorkspaceID("ws-a")
    private static let b = WorkspaceID("ws-b")
    private static let sections = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: a, title: "a")),
            .workspace(SidebarWorkspace(id: b, title: "b")),
        ]),
    ]

    @Test func leavingAWorkspaceStampsIt() throws {
        let model = SidebarModel(sections: Self.sections)
        model.activeWorkspaceID = Self.a
        let before = Date()
        model.activeWorkspaceID = Self.b
        let stamp = try #require(SidebarLookedStore.shared.stamps[Self.a])
        #expect(stamp >= before)
    }

    @Test func theDigestCountsOnlyWhatHappenedSince() {
        let looked = Date(timeIntervalSince1970: 1_000)
        let at = { (seconds: TimeInterval) in Date(timeIntervalSince1970: 1_000 + seconds) }
        let timeline = [
            SidebarTimelineEntry(kind: .finished, date: at(300)),
            SidebarTimelineEntry(kind: .waiting, date: at(200)),
            SidebarTimelineEntry(kind: .prompt, date: at(150)),
            SidebarTimelineEntry(kind: .finished, date: at(100)),
            SidebarTimelineEntry(kind: .failed, date: at(-50)),
        ]
        let text = WorkspaceHoverCardContent.sinceLooked(timeline, after: looked)
        #expect(text == CmuxNextSidebar.Strings.sinceLooked([CmuxNextSidebar.Strings.sinceLookedDone(2), CmuxNextSidebar.Strings.sinceLookedAsked(1)]
            .joined(separator: WorkspaceRowContent.separator)))
        #expect(WorkspaceHoverCardContent.sinceLooked(timeline, after: at(400)) == nil, "nothing since: no line")
    }

    @Test func theCardLeadsWithTheDigest() {
        let looked = Date(timeIntervalSince1970: 1_000)
        let timeline = [SidebarTimelineEntry(kind: .finished, date: Date(timeIntervalSince1970: 1_100))]
        let workspace = SidebarWorkspace(id: Self.a, title: "a")
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date(), options: WorkspaceHoverCardOptions(),
                                                  timeline: timeline, looked: looked)
        #expect(card.facts.first?.kind == WorkspaceHoverCardContent.sinceLookedKind)
        let unlooked = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date(), options: WorkspaceHoverCardOptions(),
                                                      timeline: timeline)
        #expect(!unlooked.facts.contains { $0.kind == WorkspaceHoverCardContent.sinceLookedKind })
    }

    @Test func theStoreKeepsItsNewestStamps() {
        let store = SidebarLookedStore(defaults: nil)
        for index in 0...SidebarLookedStore.limit {
            store.stamp(WorkspaceID("ws-\(index)"), now: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        #expect(store.stamps.count == SidebarLookedStore.limit)
        #expect(store.stamps[WorkspaceID("ws-0")] == nil, "the oldest stamp goes first")
    }
}
