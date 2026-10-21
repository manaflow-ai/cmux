@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// An OSC 7501 alert's banner reads in the app's language (cx-6so.36.8): the app titles it from
/// the record it matched ("<title, else app, else A program> <verb>", like the daemon's English).
/// A terminal notification with no record keeps the daemon's own title.
@MainActor
struct ProgramAlertTitleTests {
    /// The banner title a German app posts for a daemon `terminal` notification on a tab whose
    /// session stream carries `records`.
    func banner(records: String, title: String, body: String = "", level: String) throws -> String? {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":{"program_status":\#(records)}}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)

        let wire = #"{"notification":5,"title":"\#(title)","body":"\#(body)","level":"\#(level)","surface":1,"source":"terminal"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        service.localizations = ["de"]
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        service.deliver(notification, source: .terminal, located: located, decision: decision,
                        program: service.programStatus(of: notification, source: .terminal, located: located))
        // The headline is the subtitle; the title says where (workspace › tab).
        return service.desktop.posted.last?.subtitle
    }

    @Test func aBlockedProgramsBannerReadsInTheAppsLanguage() throws {
        let records = #"[{"id":"","state":"blocked","kind":"permission","app":"terraform","title":"terraform apply","msg":"Apply 3 changes?","updated_seq":"2"}]"#
        #expect(try banner(records: records, title: "terraform apply needs approval", body: "Apply 3 changes?", level: "warning")
            == "terraform apply benötigt Freigabe")
    }

    @Test func aFailureWithoutANameIsAProgramInTheAppsLanguage() throws {
        let records = #"[{"id":"","state":"error","updated_seq":"3"}]"#
        #expect(try banner(records: records, title: "A program failed", level: "error") == "Ein Programm ist fehlgeschlagen")
    }

    @Test func aNotificationWithoutARecordKeepsTheDaemonsTitle() throws {
        #expect(try banner(records: "[]", title: "Build finished", level: "info") == "Build finished")
    }
}
