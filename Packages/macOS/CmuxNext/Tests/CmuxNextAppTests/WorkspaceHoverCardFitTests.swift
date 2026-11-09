import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-07, on the sidebar's workspace hover card: "the min can be a bit smaller", "I don't want it to
/// disappear as quickly as other ones would", "if the inner tab is the exact same name as the workspace, I feel like
/// there's something that is kind of sort of redundant there".
@MainActor @Suite(.serialized) struct WorkspaceHoverCardFitTests {
    private func workspace(_ title: String) -> SidebarWorkspace {
        SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-fit"), title: title)
    }

    @Test func theCardLingersWhenThePointerLeavesItsRow() {
        #expect(SidebarTunables.workspaceHoverCardLeave.defaultValue == .lingers)
        #expect(WorkspaceHoverCardController().leave == .lingers, "the workspace card hides as fast as a tab's card")
    }

    @Test func theNarrowestCardIsNarrowerThanBefore() {
        #expect(SidebarHoverCardMetrics.minTextColumnInTitles == 10)
        let tokens = WorkspaceHoverCardView.tokens
        #expect(tokens.minWidth < tokens.width - tokens.titleSize * 8, "the card's floor is still near its usual width")
    }

    @Test func aNameItsOneTabRepeatsShowsOnce() throws {
        #expect(SidebarTunables.workspaceHoverCardTitle.defaultValue == .unlessRepeated)
        let rule = WorkspaceHoverCardTitle.unlessRepeated
        #expect(!rule.showsTitle("Deploy", tabTitles: ["deploy "], expanded: false))
        #expect(rule.showsTitle("Deploy", tabTitles: ["Deploy", "logs"], expanded: false))
        #expect(rule.showsTitle("Deploy", tabTitles: ["zsh"], expanded: false))
        #expect(rule.showsTitle("Deploy", tabTitles: ["Deploy"], expanded: true), "Show details hides the name")
        #expect(WorkspaceHoverCardTitle.always.showsTitle("Deploy", tabTitles: ["Deploy"], expanded: false))
        #expect(!WorkspaceHoverCardTitle.withDetails.showsTitle("Deploy", tabTitles: ["zsh", "logs"], expanded: false))

        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace("Deploy"), now: Date()))
        card.configureTabs(title: "ws-fit", tabs: [SidebarTab(id: TabID("t1"), title: "Deploy")])
        #expect(card.drawnTitleHidden, "the card repeats its one tab's name above it")
        card.configureTabs(title: "ws-fit", tabs: [SidebarTab(id: TabID("t1"), title: "Deploy"), SidebarTab(id: TabID("t2"), title: "logs")])
        #expect(!card.drawnTitleHidden)
        card.configureTabs(title: "ws-fit", tabs: [SidebarTab(id: TabID("t1"), title: "Deploy")])
        card.expandDetails()
        #expect(!card.drawnTitleHidden, "the details lost the workspace's name")
    }
}
