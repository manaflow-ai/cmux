#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// A busy Mac changes its workspaces many times a second. Only the part of the Workspaces page
/// that shows them (the rows and the subtitle) re-runs for each change; the page around them,
/// with its dialogs, sheets and toolbar host, does not (it read the workspaces and re-ran whole).
@MainActor
@Suite(.serialized) struct WorkspacesPageBodyTests {
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    @Test func rowChangesReRunTheRowsNotThePage() throws {
        let store = AppStore.mock()
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let page = NavigationStack { WorkspacesList(store: store, creator: creator, open: { _ in }) }
        let host = UIHostingController(rootView: page)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let probe = ListApplyProbe.shared
        probe.counting = true
        defer {
            window.isHidden = true
            probe.counting = false
            _ = probe.takeCounts()
        }
        for _ in 0..<5 { settle() }
        _ = probe.takeCounts()
        let first = try #require(store.activeWorkspaces.first)
        for round in 0..<10 {
            var row = try #require(store.workspace(id: first.id))
            row.title = "busy \(round)"
            store.updateWorkspaces(macID: row.macID, rows: [row])
            settle()
        }
        let counts = probe.takeCounts()
        #expect((counts["ws.rows.body"] ?? 0) >= 10, "the rows did not follow the changes: \(counts)")
        #expect((counts["ws.list.body"] ?? 0) == 0, "the page re-ran for row changes: \(counts)")
    }
}
#endif
