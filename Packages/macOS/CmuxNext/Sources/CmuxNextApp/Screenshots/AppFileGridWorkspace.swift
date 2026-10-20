import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFileGrid
import Foundation

/// How file grids open, reveal and trash files in the app: opens and
/// reveals run off the main thread (cx-050n, `NSWorkspace+Background`), so
/// a slow Launch Services lookup never stalls the window. Its questions and
/// errors are cmux dialogs, which show their keys (u2647).
@MainActor
final class AppFileGridWorkspace: FileGridWorkspace {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(_ urls: [URL]) {
        for url in urls { workspace.openInBackground(url) }
    }

    func reveal(_ urls: [URL]) {
        workspace.revealInBackground(urls)
    }

    func recycle(_ urls: [URL]) async throws {
        _ = try await workspace.recycle(urls)
    }

    func askName(title: String, initial: String, confirm: String, cancel: String, in window: NSWindow?) async -> String? {
        let spec = CmuxDialogSpec(title: title, fields: [.text("name", initial: initial)],
                                  buttons: [.cancel(cancel), CmuxDialogButton(id: "rename", title: confirm, role: .default)],
                                  identifier: "cmux.filegrid.rename")
        let answer = await CmuxDialogCenter.shared.present(spec, in: window.map(CmuxDialogScope.window) ?? .app)
        return answer.button == "rename" ? answer.text("name") : nil
    }

    func report(_ message: String, detail: String?, in window: NSWindow?) {
        let spec = CmuxDialogSpec(title: message, lines: detail.map { [$0] } ?? [], buttons: [.ok()],
                                  identifier: "cmux.filegrid.error")
        CmuxDialogCenter.shared.present(spec, in: window.map(CmuxDialogScope.window) ?? .app) { _ in }
    }
}
