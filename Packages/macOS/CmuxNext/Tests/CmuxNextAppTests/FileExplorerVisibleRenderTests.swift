import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFilesUI
import CmuxNextWakeups
import Foundation
import Testing

/// The Files and Find sections render through a `VisibleObservation` on their own node
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, FG316, rule 9): a hidden section applies nothing
/// and renders once when it shows, while the Files tree's folder follow (a `ServiceObservation`)
/// still roots the model while nothing shows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FileExplorerVisibleRenderTests {
    static let match = RipgrepMatch(path: "/tmp/project/a.txt", relativePath: "a.txt", line: 1, column: 1, preview: "needle")

    @Test func aHiddenFindSectionRendersNothingAndRendersOnceOnShow() async throws {
        let model = FindSectionModel { _, _ in .matches([Self.match], limited: false) }
        let view = FindSectionView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                   rootFolder: { URL(fileURLWithPath: "/tmp/project", isDirectory: true) },
                                   effects: NullFileExplorerEffects())
        // In no window: the view's node is under its hidden off-window root.
        await model.search("needle")
        #expect(model.results == [Self.match])
        #expect(view.table.numberOfRows == 0, "a hidden Find section rendered its results")
        let window = VisibilityNode(root: "test.window", own: .visible)
        try view.visibilityNode.attach(to: window)
        #expect(view.table.numberOfRows == 1, "the Find section did not render on show")
    }

    @Test func aHiddenFilesSectionFollowsTheFolderAndRendersItOnShow() async throws {
        let root = try FileExplorerTests.folder()
        let model = FileExplorerModel()
        let view = FileExplorerSectionView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                           rootFolder: { root }, perform: { _ in }, rowMenu: { _ in nil })
        // The follow is a service: the hidden section's model still roots at the folder and lists it.
        await FileExplorerFollowTests.root(of: model, becomes: root.standardizedFileURL)
        // The listing ends after the git read (a process), so wait for the rows, not a yield count.
        for await rows in ObservationStream({ model.rows }) where !rows.isEmpty { break }
        #expect(model.rows.map(\.name) == ["Sources", "b.txt", "README.md"])
        #expect(view.table.numberOfRows == 0, "a hidden Files section rendered its rows")
        let window = VisibilityNode(root: "test.window", own: .visible)
        try view.visibilityNode.attach(to: window)
        #expect(view.table.numberOfRows == 3, "the Files section did not render on show")
    }
}
