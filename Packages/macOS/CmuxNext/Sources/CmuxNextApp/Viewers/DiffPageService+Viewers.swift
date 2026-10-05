import AppKit

/// The diff host behind R89's open actions: ``DiffViewerOpening`` is
/// ``DiffPageService/open(folder:source:in:focus:)``, and the empty state's
/// `cmux.diff.chooseFolder` asks with the cmux picker instead of the system
/// panel.
extension DiffPageService: DiffViewerOpening {
    func openDiff(directory: String, in pane: PaneController, focus: Bool) async throws {
        do {
            try await open(folder: URL(fileURLWithPath: directory, isDirectory: true), in: pane, focus: focus)
        } catch {
            throw ActionFailure(message: DiffPageStrings.notRepository)
        }
    }
}

/// `cmux.diff.chooseFolder` through the cmux picker (folder mode, the diff
/// recents first).
final class PickerDiffFolderChooser: DiffFolderChoosing {
    private unowned let viewers: ViewerService

    init(viewers: ViewerService) {
        self.viewers = viewers
    }

    func chooseFolder(start: URL?, anchor: NSWindow?) async -> URL? {
        await viewers.picker.open(.init(choose: .folders, startDirectory: start, recents: [.diff]), over: anchor)?.first
    }
}
