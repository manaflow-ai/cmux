import AppKit
import Bonsplit
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

/// A container that can open one of its file surfaces in a terminal editor.
///
/// Only containers that own a terminal-capable surface tree conform, so a panel
/// hosted elsewhere — the Dock — leaves its binding `nil` and hides the action.
@MainActor
protocol TerminalEditorOpeningHost: AnyObject {
    @discardableResult
    func openTerminalEditorSurface(forPanelId panelId: UUID) -> TerminalPanel?
}

extension Workspace: TerminalEditorOpeningHost {
    @discardableResult
    func openTerminalEditorSurface(forPanelId panelId: UUID) -> TerminalPanel? {
        let resolvedEditor = TerminalEditorResolutionStore.cached()
        if resolvedEditor == nil {
            TerminalEditorResolutionStore.refreshInBackground()
        }
        return openTerminalEditorSurface(
            forPanelId: panelId,
            userShell: WorkspaceInitialCommandLoginShell.resolvedUserShell(),
            resolvedEditor: resolvedEditor,
            placement: TerminalEditorPlacementSettings.resolvedPlacement()
        )
    }

    /// Opens the file shown by `panelId` in a terminal surface running the
    /// user's terminal editor.
    ///
    /// - Parameters:
    ///   - panelId: A file-preview or markdown panel.
    ///   - userShell: The shell that runs the editor.
    ///   - resolvedEditor: A previously resolved editor, which avoids paying
    ///     interactive shell startup on every open. When `nil`, the editor is
    ///     resolved by an interactive shell instead.
    ///   - placement: Where the terminal surface goes.
    /// - Returns: The created terminal panel, or `nil` when the panel is not a
    ///   file surface or is no longer in the tree.
    @discardableResult
    func openTerminalEditorSurface(
        forPanelId panelId: UUID,
        userShell: String?,
        resolvedEditor: ResolvedTerminalEditor?,
        placement: TerminalEditorPlacement
    ) -> TerminalPanel? {
        guard let filePath = fileSurfacePath(forPanelId: panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let startupCommand: String
        var startupEnvironment: [String: String] = [:]
        if let resolvedEditor {
            // No shell in between: the editor is already an absolute path, and
            // carrying the shell's PATH keeps the tools it spawns reachable.
            startupCommand = TerminalEditorCommand.command(
                forOpening: fileURL,
                resolvedEditor: resolvedEditor
            )
            startupEnvironment["PATH"] = resolvedEditor.pathEnvironment
        } else {
            startupCommand = WorkspaceInitialCommandLoginShell.wrapInteractive(
                TerminalEditorCommand.command(forOpening: fileURL, userShell: userShell),
                userShell: userShell
            )
        }

        let sourceIndex = indexInPane(forPanelId: panelId)
        guard let terminalPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: fileURL.deletingLastPathComponent().path,
            initialCommand: startupCommand,
            startupEnvironment: startupEnvironment,
            commandExitPolicy: .closeOnExit
        ) else {
            return nil
        }

        // The file surface deliberately stays open. It is what the user returns
        // to when the editor exits, and it keeps the editor from being the
        // workspace's last panel — a child exit there collapses the workspace.
        if placement == .afterSource,
           let sourceIndex,
           let tabId = surfaceIdFromPanelId(terminalPanel.id) {
            _ = bonsplitController.reorderTab(tabId, toIndex: sourceIndex + 1)
        }
        return terminalPanel
    }

    private func fileSurfacePath(forPanelId panelId: UUID) -> String? {
        switch panels[panelId] {
        case let panel as FilePreviewPanel:
            return panel.filePath
        case let panel as MarkdownPanel:
            return panel.filePath
        default:
            return nil
        }
    }
}

extension Workspace {
    @discardableResult
    func openFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [any Panel] = []

        for filePath in filePaths {
            let panel: (any Panel)?
            let pathExtension = (filePath as NSString).pathExtension.lowercased()
            if pathExtension == "xcodeproj" || pathExtension == "xcworkspace" {
                panel = newProjectSurface(
                    inPane: paneId,
                    projectPath: filePath,
                    focus: shouldFocusNewTabs,
                    targetIndex: nextIndex
                )
            } else if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
                if reuseExisting {
                    panel = openOrFocusMarkdownSurface(
                        inPane: paneId,
                        filePath: filePath,
                        focus: shouldFocusNewTabs
                    )
                } else {
                    panel = newMarkdownSurface(
                        inPane: paneId,
                        filePath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                }
            } else if reuseExisting {
                panel = openOrFocusFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: shouldFocusNewTabs
                )
            } else {
                panel = newFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: shouldFocusNewTabs,
                    targetIndex: nextIndex
                )
            }

            if let panel {
                openedPanels.append(panel)
                if let index = nextIndex {
                    nextIndex = index + 1
                }
            }
        }

        return openedPanels
    }

    @discardableResult
    func openFilePreviewSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [FilePreviewPanel] {
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [FilePreviewPanel] = []

        for filePath in filePaths {
            let panel: FilePreviewPanel?
            if reuseExisting {
                panel = openOrFocusFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: shouldFocusNewTabs
                )
            } else {
                panel = newFilePreviewSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: shouldFocusNewTabs,
                    targetIndex: nextIndex
                )
            }

            if let panel {
                openedPanels.append(panel)
                if let index = nextIndex {
                    nextIndex = index + 1
                }
            }
        }

        return openedPanels
    }
}

/// Where the terminal editor opens relative to the file surface it came from.
enum TerminalEditorPlacement: String, CaseIterable, Sendable {
    /// Immediately to the right of the file surface.
    case afterSource
    /// At the end of the pane's tab strip.
    case endOfTabStrip
}

enum TerminalEditorPlacementSettings {
    static let key = "terminalEditorPlacement"
    static let defaultValue: TerminalEditorPlacement = .afterSource

    /// Parses a raw config value, falling back to ``defaultValue`` for `nil` or
    /// unrecognized input.
    static func placement(forRawValue raw: String?) -> TerminalEditorPlacement {
        guard let raw, let placement = TerminalEditorPlacement(rawValue: raw) else {
            return defaultValue
        }
        return placement
    }

    static func resolvedPlacement(defaults: UserDefaults = .standard) -> TerminalEditorPlacement {
        placement(forRawValue: defaults.string(forKey: key))
    }
}

/// Caches the editor resolved from the user's interactive shell.
///
/// Interactive shell startup dominates the cost of opening the editor, so it is
/// paid in the background rather than on the user's keystroke.
@MainActor
enum TerminalEditorResolutionStore {
    static let defaultsKey = "terminalEditorResolvedEditor"

    private static var inMemoryValue: ResolvedTerminalEditor?

    static func cached(defaults: UserDefaults = .standard) -> ResolvedTerminalEditor? {
        if let inMemoryValue { return inMemoryValue }
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ResolvedTerminalEditor.self, from: data) else {
            return nil
        }
        inMemoryValue = decoded
        return decoded
    }

    static func store(_ resolved: ResolvedTerminalEditor, defaults: UserDefaults = .standard) {
        inMemoryValue = resolved
        guard let data = try? JSONEncoder().encode(resolved) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Re-resolves the editor off the main thread, adopting the result when the
    /// shell reports an absolute path.
    static func refreshInBackground(
        userShell: String = WorkspaceInitialCommandLoginShell.resolvedUserShell()
    ) {
        Task.detached(priority: .utility) {
            guard let resolved = probe(userShell: userShell) else { return }
            await MainActor.run { store(resolved) }
        }
    }

    nonisolated static func probe(userShell: String) -> ResolvedTerminalEditor? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        process.arguments = ["-ilc", TerminalEditorProbe.payload]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return TerminalEditorProbe.parse(text)
    }
}

/// A file surface that can hand its file off to a terminal editor.
@MainActor
protocol TerminalEditorOpenablePanel: AnyObject {
    var id: UUID { get }
    var isDirty: Bool { get }
    var terminalEditorHost: (any TerminalEditorOpeningHost)? { get }

    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

extension FilePreviewPanel: TerminalEditorOpenablePanel {}

extension MarkdownPanel: TerminalEditorOpenablePanel {}

extension TerminalEditorOpenablePanel {
    /// Whether the terminal-editor action is available for this panel.
    var canOpenInTerminalEditor: Bool {
        terminalEditorHost != nil
    }

    /// Hands this panel's file to a terminal editor, saving first when the
    /// buffer is dirty and the user confirms.
    ///
    /// - Parameter confirmSaveBeforeOpen: Consulted only when the buffer is
    ///   dirty. Returning `false` cancels the handoff.
    func openInTerminalEditor(
        confirmSaveBeforeOpen: () -> Bool = TerminalEditorSavePrompt.run
    ) {
        guard let host = terminalEditorHost else { return }

        guard isDirty else {
            host.openTerminalEditorSurface(forPanelId: id)
            return
        }

        guard confirmSaveBeforeOpen() else { return }
        let saveTask = saveTextContent()
        let panelId = id
        Task { @MainActor [weak host] in
            await saveTask?.value
            host?.openTerminalEditorSurface(forPanelId: panelId)
        }
    }
}

/// Asks whether to save a dirty buffer before handing the file to an editor.
@MainActor
enum TerminalEditorSavePrompt {
    static func run() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "filePreview.openInTerminalEditor.unsaved.title",
            defaultValue: "Save before opening in the editor?"
        )
        alert.informativeText = String(
            localized: "filePreview.openInTerminalEditor.unsaved.message",
            defaultValue: "This file has unsaved changes, and the editor opens the version on disk."
        )
        alert.addButton(withTitle: String(
            localized: "filePreview.openInTerminalEditor.unsaved.save",
            defaultValue: "Save & Open"
        ))
        alert.addButton(withTitle: String(
            localized: "filePreview.openInTerminalEditor.unsaved.cancel",
            defaultValue: "Cancel"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
