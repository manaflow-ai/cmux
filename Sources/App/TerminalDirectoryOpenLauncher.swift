import AppKit
import Foundation

@MainActor
enum TerminalDirectoryOpenLauncher {
    static func currentDirectoryURL(in tabManager: TabManager?) -> URL? {
        guard let workspace = tabManager?.selectedWorkspace else { return nil }
        let focusedPanelDirectory = workspace.focusedPanelId.flatMap { workspace.panelDirectories[$0] }
        return firstValidDirectoryURL(in: [focusedPanelDirectory, workspace.currentDirectory])
    }

    static func firstValidDirectoryURL(in rawDirectories: [String?]) -> URL? {
        for rawDirectory in rawDirectories {
            let trimmed = rawDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return nil
    }

    static func openCurrentDirectory(
        in target: TerminalDirectoryOpenTarget,
        tabManager: TabManager?
    ) -> Bool {
        guard let directoryURL = currentDirectoryURL(in: tabManager) else { return false }
        return openDirectory(directoryURL, in: target, tabManager: tabManager)
    }

    static func openDirectory(
        _ directoryURL: URL,
        in target: TerminalDirectoryOpenTarget,
        tabManager: TabManager?
    ) -> Bool {
        switch target {
        case .finder:
            return NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
        case .vscodeInline:
            return AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }
}
