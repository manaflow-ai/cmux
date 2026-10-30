import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextFilesUI

/// The App's ``FileExplorerEffects``: cmux viewers through the link opener
/// (beside the active window's focused pane), the rest through NSWorkspace's
/// background calls.
@MainActor
final class AppFileExplorerEffects: FileExplorerEffects {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func openInCmux(_ file: URL, at position: FileLineLocation?) -> Bool {
        guard let services else { return false }
        return services.linkOpener.openFile(file, from: services.windows.active?.focusedPane, line: position)
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
        guard let appURL = Self.application(named: app) else { throw FileExplorerError.noSuchApp(app) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([item], withApplicationAt: appURL, configuration: configuration)
        } catch {
            throw FileExplorerError.openFailed(item.lastPathComponent)
        }
    }

    /// An app by bundle id, `.app` path, or name in the Applications folders.
    private static func application(named app: String) -> URL? {
        let workspace = NSWorkspace.shared
        if let byID = workspace.urlForApplication(withBundleIdentifier: app) { return byID }
        let expanded = (app as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app"), FileManager.default.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        let name = app.hasSuffix(".app") ? app : app + ".app"
        for folder in ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            let candidate = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}
