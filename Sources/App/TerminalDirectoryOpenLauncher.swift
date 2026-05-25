import AppKit
import Foundation

@MainActor
enum TerminalDirectoryOpenLauncher {
    typealias ApplicationOpenCompletion = @MainActor (Error?) -> Void
    typealias ApplicationOpenHandler = (
        _ urls: [URL],
        _ applicationURL: URL,
        _ configuration: NSWorkspace.OpenConfiguration,
        _ completion: @escaping ApplicationOpenCompletion
    ) -> Void

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
        tabManager: TabManager?,
        onOpenFailure: ApplicationOpenCompletion? = nil
    ) -> Bool {
        guard let directoryURL = currentDirectoryURL(in: tabManager) else { return false }
        return openDirectory(
            directoryURL,
            in: target,
            tabManager: tabManager,
            onOpenFailure: onOpenFailure
        )
    }

    static func openDirectory(
        _ directoryURL: URL,
        in target: TerminalDirectoryOpenTarget,
        tabManager: TabManager?,
        onOpenFailure: ApplicationOpenCompletion? = nil,
        applicationURLProvider: (TerminalDirectoryOpenTarget) -> URL? = { $0.applicationURL() },
        openWithApplication: ApplicationOpenHandler? = nil
    ) -> Bool {
        switch target {
        case .finder:
            return NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
        case .vscodeInline:
            return AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
        default:
            guard let applicationURL = applicationURLProvider(target) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            let openWithApplication = openWithApplication ?? openURLsWithApplication
            openWithApplication([directoryURL], applicationURL, configuration) { error in
                guard error != nil else { return }
                onOpenFailure?(error)
            }
            return true
        }
    }

    private static func openURLsWithApplication(
        _ urls: [URL],
        applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion: @escaping ApplicationOpenCompletion
    ) {
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
            Task { @MainActor in
                completion(error)
            }
        }
    }
}
