import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import Foundation
import Observation
import Testing

/// The Files tree follows the focused terminal's folder: a `cd` in it, or focus moving to another
/// terminal, roots the tree there; focus on a tab with no local folder (a browser page) keeps it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FileExplorerFollowTests {
    @MainActor @Observable final class FocusedFolder {
        var folder: URL?
    }

    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("\(name).txt"))
        return url.standardizedFileURL
    }

    static func root(of model: FileExplorerModel, becomes expected: URL) async {
        for await root in ObservationStream({ model.root }) where root == expected { return }
    }

    @Test func theTreeFollowsTheFocusedFolderAndKeepsItWhenFocusHasNone() async throws {
        let first = try Self.folder("first"), second = try Self.folder("second")
        let focused = FocusedFolder()
        focused.folder = first
        let model = FileExplorerModel()
        let view = FileExplorerSectionView(model: model, rootFolder: { focused.folder }, perform: { _ in }, rowMenu: { _ in nil })
        await Self.root(of: model, becomes: first)
        // A `cd` in the focused terminal (its folder changes) moves the tree.
        focused.folder = second
        await Self.root(of: model, becomes: second)
        // Focus on a browser tab: no folder, the tree stays.
        focused.folder = nil
        view.follow()
        #expect(model.root == second)
        // Focus back on the first terminal (a focus change, no observed change).
        focused.folder = first
        view.follow()
        await Self.root(of: model, becomes: first)
        withExtendedLifetime(view) {}
    }
}
