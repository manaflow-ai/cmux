import AppKit
import CmuxNextCompat
import CmuxNextFilesUI
import CmuxNextPages

/// The App's ``FileExplorerEffects``: cmux viewers through the link opener
/// (beside the active window's focused pane), the rest through NSWorkspace's
/// background calls.
@MainActor
final class AppFileExplorerEffects: FileExplorerEffects {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func openInCmux(_ file: URL, at position: FilePosition?) -> Bool {
        guard let services else { return false }
        return services.linkOpener.openFile(file, from: services.windows.active?.focusedPane, at: position)
    }

    func openAsText(_ file: URL) -> Bool {
        guard let services else { return false }
        return services.linkOpener.openFile(file, from: services.windows.active?.focusedPane, asText: true)
    }

    func openInDefaultApp(_ item: URL) {
        NSWorkspace.shared.openInBackground(item)
    }

    func revealInFinder(_ item: URL) {
        NSWorkspace.shared.revealInBackground([item])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ item: URL, withApp app: String) async throws {
        // A bundle id, an `.app` path or an app name, resolved by Launch Services on the system lane.
        guard let queries = services?.workspaceQueries,
              let appURL = try await queries.value(LinkMenu.application(named: app), priority: .userBlocking) else {
            throw FileExplorerError.noSuchApp(app)
        }
        guard await NSWorkspace.shared.openedInBackground([item], withApplicationAt: appURL) else {
            throw FileExplorerError.openFailed(item.lastPathComponent)
        }
    }
}
