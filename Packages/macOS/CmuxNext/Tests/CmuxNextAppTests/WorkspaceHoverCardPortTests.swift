@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Remote ergonomics flow 5, ports: a dev server a workspace's terminal serves shows as the workspace's `ports`
/// entry, and its hover card offers each port as one row that opens it with one click, details shut or open, on this
/// Mac or on another machine (where the workspace's browser tab reaches that machine's localhost).
@MainActor @Suite struct WorkspaceHoverCardPortTests {
    static func workspace(_ ports: String?) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-web"), title: "web")
        workspace.ports = ports
        return workspace
    }

    @Test func eachPortOfTheEntryIsARowThatOpensItsLocalhost() {
        let card = WorkspaceHoverCardContent.make(Self.workspace(":3000, :5173"), machine: nil, now: Date())
        #expect(card.ports.map(\.text) == ["localhost:3000", "localhost:5173"])
        #expect(card.ports.map(\.link) == ["http://localhost:3000/", "http://localhost:5173/"])
        // The entry reads once: as its rows, not again among the details.
        #expect(!card.facts.contains { $0.kind == "ports" })
        #expect(card.cardFacts.facts.contains { $0.kind == "ports" && $0.text == ":3000, :5173" })
    }

    @Test func anEntryWithNoPortToOpenReadsAsBefore() {
        let card = WorkspaceHoverCardContent.make(Self.workspace("web app"), machine: nil, now: Date())
        #expect(card.ports.isEmpty)
        #expect(card.facts.contains { $0.kind == "ports" && $0.text == "web app" })
        let unanswered = WorkspaceHoverCardContent.make(Self.workspace(":3000"), machine: nil, now: Date(), options: WorkspaceHoverCardOptions(),
                                                        timeline: [], portLinks: { _ in nil })
        #expect(unanswered.ports.isEmpty)
        #expect(unanswered.facts.contains { $0.kind == "ports" && $0.text == ":3000" })
    }

    @Test func theCollapsedCardShowsThePortAndOneClickOpensIt() throws {
        let view = WorkspaceHoverCardView()
        view.configure(WorkspaceHoverCardContent.make(Self.workspace(":5173"), machine: nil, now: Date()))
        #expect(!view.isDetailsExpanded)
        #expect(view.lines.contains("localhost:5173"))
        var opened: [(String, String)] = []
        view.onOpenPort = { opened.append(($0, $1)) }
        try #require(view.portViews.first).performClick(nil)
        #expect(opened.map(\.0) == ["http://localhost:5173/"])
        #expect(opened.map(\.1) == ["localhost:5173"])
    }

    @Test func aWorkspaceWithoutPortsHasNoPortRow() {
        let view = WorkspaceHoverCardView()
        view.configure(WorkspaceHoverCardContent.make(Self.workspace(nil), machine: nil, now: Date()))
        let allHidden = view.portViews.allSatisfy { $0.isHidden }
        #expect(allHidden)
    }

    @Test func openingAPortChangesNothingInTheSidebar() {
        let model = SidebarModel()
        let before = model.sections
        model.apply(.openPort(workspace: WorkspaceID("ws-web"), url: "http://localhost:5173/", label: "localhost:5173"))
        #expect(model.sections == before)
        #expect(SidebarIntent.openPort(workspace: WorkspaceID("ws-web"), url: "http://localhost:5173/", label: "localhost:5173")
            .saveAction.title == "localhost:5173")
    }
}
