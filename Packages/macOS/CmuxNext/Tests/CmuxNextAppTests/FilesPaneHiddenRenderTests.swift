import AppKit
import CmuxNextFiles
@testable import CmuxNextFilesUI
import CmuxNextWakeups
import Foundation
import Testing

/// The Files pane renders through a `VisibleObservation` on its own node (p06-scheduler-337, rule 9),
/// not a main-actor `ObservationStream` task: a hidden pane (an unselected tab, a hidden pane, an
/// occluded window) applies no model change, and renders once, the current state, when it shows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FilesPaneHiddenRenderTests {
    @Test func aHiddenPaneRendersNothingAndRendersOnceOnShow() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p06-337-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "FilesPaneHiddenRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let model = FileBrowserModel(folder: folder, work: mainWork, viewMode: .list)
        let pane = FilesPaneView(model: model, sidebar: SidebarModel(home: folder, defaults: defaults, volumes: { [] }),
                                 icons: FileIconProvider(queries: nil), home: folder, mainWork: mainWork) { _ in }
        defer { pane.stop() }
        // In no window the pane's node is under its hidden off-window root; init rendered the list once.
        #expect(pane.currentContent is FileListView)
        model.viewMode = .columns
        #expect(pane.currentContent is FileListView, "a hidden pane rendered a model change")
        let window = VisibilityNode(root: "test.window", own: .visible)
        try pane.visibilityNode.attach(to: window)
        #expect(pane.currentContent is FileColumnsView, "the pane did not render the current state on show")
    }
}
