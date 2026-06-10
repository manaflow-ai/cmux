import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Service, external file, and URL open handling
extension AppDelegate {
    private static let serviceErrorNoPath = NSString(string: String(localized: "error.clipboardFolderPath", defaultValue: "Could not load any folder path from the clipboard."))
    enum ServiceOpenTarget {
        case window
        case workspace
    }

    func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = externalOpenDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        let pathURLs = PasteboardFileURLReader.fileURLs(from: pasteboard)
        if !pathURLs.isEmpty {
            return pathURLs
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        openWorkspaceForExternalDirectory(
            workingDirectory: workingDirectory,
            debugSource: "service.openTab"
        )
    }

    func prepareForExplicitOpenIntentAtStartup() {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
        }
    }

    func externalOpenDirectories(from urls: [URL]) -> [String] {
        // LaunchServices can surface the running app bundle on relaunch; ignore self paths so
        // they do not get treated as explicit folder opens and suppress session restore.
        FinderServicePathResolver.orderedUniqueDirectories(
            from: urls.filter { $0.isFileURL },
            excludingDescendantsOf: [Bundle.main.bundleURL]
        )
    }

    func externalOpenFileURLs(from urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var fileURLs: [URL] = []
        for url in urls where url.isFileURL && !externalOpenURLIsDirectory(url) {
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !externalOpenURLIsDescendantOfCurrentBundle(standardized) else { continue }
            let path = standardized.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            fileURLs.append(url.standardizedFileURL)
        }
        return fileURLs
    }

    func externalOpenURLIsDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.hasDirectoryPath {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func externalOpenURLIsDescendantOfCurrentBundle(_ url: URL) -> Bool {
        let pathComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let bundleComponents = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard pathComponents.count >= bundleComponents.count else { return false }
        return Array(pathComponents.prefix(bundleComponents.count)) == bundleComponents
    }

    func openWorkspaceForExternalDirectory(
        workingDirectory: String,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    func openTerminalDefaultFileRequest(
        _ request: TerminalDefaultFileOpenRequest,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: request.workingDirectory,
            initialTerminalInput: request.initialInput,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(
            initialWorkspaceTitle: request.fileURL.lastPathComponent,
            initialWorkingDirectory: request.workingDirectory,
            initialTerminalInput: request.initialInput
        )
    }

    @discardableResult
    func pasteTextInPreferredMainWindowFromExternalLink(
        _ text: String,
        preferredWindow: NSWindow? = nil,
        shouldBringToFront: Bool = true,
        debugSource: String = "externalLink",
        onSendFailure: (() -> Void)? = nil
    ) -> Bool {
        let context: MainWindowContext? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialTerminalInput: "", shouldActivate: shouldBringToFront)
            return mainWindowContexts.values.first { $0.windowId == windowId }
        }()
        guard let context else { return false }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if shouldBringToFront, let window {
            bringToFront(window)
            setActiveMainWindow(window)
        }

        let workspace = context.tabManager.selectedWorkspace
            ?? context.tabManager.addWorkspace(select: shouldBringToFront, autoWelcomeIfNeeded: false)
        let terminalPanel = workspace.focusedTerminalPanel
            ?? workspace.newTerminalSurfaceInFocusedPane(focus: shouldBringToFront)
        guard let terminalPanel else { return false }

#if DEBUG
        cmuxDebugLog("textURL.paste source=\(debugSource) workspace=\(workspace.id.uuidString.prefix(8)) surface=\(terminalPanel.id.uuidString.prefix(8)) chars=\(text.count)")
#endif
        if shouldBringToFront {
            workspace.focusPanel(terminalPanel.id)
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        sendTextWhenReady(
            text,
            to: workspace,
            preferredPanelId: terminalPanel.id,
            onFailure: onSendFailure
        )
        return true
    }

    @discardableResult
    func openFilePreviewInPreferredMainWindow(
        filePath: String,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "unspecified"
    ) -> Bool {
        let parentDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        let context: MainWindowContext? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialWorkingDirectory: parentDirectory)
            return mainWindowContexts.values.first { $0.windowId == windowId }
        }()
        guard let context else { return false }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            bringToFront(window)
            setActiveMainWindow(window)
        }

        let workspace = context.tabManager.selectedWorkspace
            ?? context.tabManager.addWorkspace(workingDirectory: parentDirectory, select: true)
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }

#if DEBUG
        cmuxDebugLog("file.externalOpen source=\(debugSource) path=\(filePath)")
#endif
        return !workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        ).isEmpty
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> UUID? {
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "request",
            source: debugSource,
            reason: "add_workspace",
            event: event,
            chosenContext: nil,
            workingDirectory: workingDirectory
        )
        #endif
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_selection_failed",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
            #endif
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_window_missing",
                event: event,
                chosenContext: context,
                workingDirectory: workingDirectory
            )
            #endif
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }

        let workspace: Workspace
        if workingDirectory != nil || initialTerminalInput != nil {
            workspace = context.tabManager.addWorkspace(
                workingDirectory: workingDirectory,
                initialTerminalInput: initialTerminalInput,
                select: true,
                autoWelcomeIfNeeded: initialTerminalInput == nil
            )
        } else {
            workspace = context.tabManager.addTab(select: true)
        }
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "created",
            source: debugSource,
            reason: "workspace_created",
            event: event,
            chosenContext: context,
            workspaceId: workspace.id,
            workingDirectory: workingDirectory
        )
        #endif
        return workspace.id
    }

    func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        if let activeManager = tabManager,
           let activeContext = mainWindowContext(for: activeManager),
           resolvedWindow(for: activeContext) == nil {
            discardOrphanedMainWindowContext(activeContext)
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "active_context_window_missing",
                event: event,
                chosenContext: nil
            )
#endif
        }

        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "key_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "main_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "ordered_windows",
                    event: event,
                    chosenContext: context
                )
                #endif
                return context
            }
        }

        pruneWindowlessMainWindowContexts()
        let fallback = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil })
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "fallback_first_context",
            event: event,
            chosenContext: fallback
        )
#endif
        return fallback
    }

}
