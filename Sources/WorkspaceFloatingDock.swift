import CoreGraphics
import Foundation
import Observation

/// One window-like Bonsplit container owned by a workspace.
@MainActor
@Observable
final class WorkspaceFloatingDock: Identifiable {
    let id: UUID
    let workspaceId: UUID
    var title: String
    var frame: CGRect
    var isPresented: Bool
    var ownsInputFocus = false

    @ObservationIgnored let store: DockSplitStore
    @ObservationIgnored let noteFilePath: String
    @ObservationIgnored let configurationSeedIdentity: String?
    @ObservationIgnored let configurationContent: DockControlDefinition?
    @ObservationIgnored let configurationBaseDirectory: String?
    @ObservationIgnored private(set) var notePanelId: UUID?

    init(
        id: UUID,
        workspaceId: UUID,
        title: String,
        frame: CGRect,
        isPresented: Bool,
        noteFilePath: String,
        existingNotePanelId: UUID? = nil,
        configurationSeedIdentity: String? = nil,
        configurationContent: DockControlDefinition? = nil,
        configurationBaseDirectory: String? = nil,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.frame = frame
        self.isPresented = isPresented
        self.noteFilePath = noteFilePath
        self.configurationSeedIdentity = configurationSeedIdentity
        self.configurationContent = configurationContent
        self.configurationBaseDirectory = configurationBaseDirectory
        self.store = DockSplitStore(
            workspaceId: workspaceId,
            scope: .workspace,
            loadsConfiguration: false,
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider
        )

        if let configurationContent, configurationContent.kind != .note {
            store.seedConfiguration(
                definitions: [configurationContent],
                baseDirectory: configurationBaseDirectory
                    ?? baseDirectoryProvider()
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
        } else {
            if let existingNotePanelId {
                notePanelId = existingNotePanelId
            } else if let rootPane = store.bonsplitController.allPaneIds.first {
                notePanelId = store.newSurface(
                    kind: .note,
                    inPane: rootPane,
                    noteFilePath: noteFilePath,
                    noteTitle: configurationContent?.title
                        ?? String(localized: "floatingDock.note.title", defaultValue: "Notes"),
                    focus: false
                )
            }
        }
    }

    var notePanel: FilePreviewPanel? {
        if let notePanelId, let panel = store.panels[notePanelId] as? FilePreviewPanel {
            return panel
        }
        return store.panels.values.first(where: { $0 is FilePreviewPanel }) as? FilePreviewPanel
    }

    func close() {
        ownsInputFocus = false
        store.closeAllPanels()
    }
}
