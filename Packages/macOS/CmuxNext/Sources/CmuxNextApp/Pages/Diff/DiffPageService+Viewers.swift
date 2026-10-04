import Foundation

/// R89's diff seam: the viewer open actions (the palette, the picker, the CLI) open diff tabs
/// through ``DiffPageService``. A folder in no repository opens the empty diff tab, as the S4
/// actions did, so the user can pick another folder there.
extension DiffPageService: DiffViewerOpening {
    func openDiff(directory: String, in pane: PaneController, focus: Bool) async throws {
        do {
            try await open(folder: URL(fileURLWithPath: directory, isDirectory: true), in: pane, focus: focus)
        } catch {
            openEmpty(in: pane, focus: focus)
        }
    }
}
