import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// A program's OSC 7501 report shows on its tab's hover card (cx-6so.36.9): the status record's
/// title and message after the program's name, on its own line under the card's facts. A record
/// with neither, or a tab without a record, adds nothing. Whitespace runs fold to one space.
@MainActor
struct ProgramStatusHoverDetailTests {
    /// The hover card's program status line of a terminal tab whose session stream carries `records`.
    func card(_ records: String) throws -> String {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":{"program_status":\#(records)}}],"extra":{"state":{}}}}}"#
        let item = try #require(SessionStreamItem.decode(Data(line.utf8)))
        store.session.apply(item, in: store)
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let card = TabHoverCardView()
        card.configure(.tab(TabItemMapping.shared.item(tab, fallbackTitle: "zsh"), facts: TabItemMapping.shared.hoverFacts(tab)))
        return card.detailText
    }

    @Test func aBlockedProgramsTitleAndMessageShowOnItsTabsCard() throws {
        let text = try card(#"[{"id":"","state":"blocked","kind":"permission","app":"terraform","title":"terraform apply","msg":"Apply 3 changes to prod?","updated_seq":"4"}]"#)
        #expect(text == "terraform: terraform apply · Apply 3 changes to prod?")
    }

    @Test func theMessageFoldsToOneLineAndARecordWithoutTextAddsNothing() throws {
        #expect(try card(#"[{"id":"","state":"working","app":"cargo","msg":"Compiling\nlinking","updated_seq":"1"}]"#) == "cargo: Compiling linking")
        #expect(try card(#"[{"id":"","state":"working","app":"cargo","updated_seq":"1"}]"#) == "")
        #expect(try card("[]") == "")
    }
}
