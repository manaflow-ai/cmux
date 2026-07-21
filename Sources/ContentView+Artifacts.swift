import AppKit
import CmuxArtifacts
import Foundation

extension ContentView {
    var selectedArtifactWorkspace: ArtifactSidebarWorkspace? {
        guard let workspace = tabManager.selectedWorkspace,
              !workspace.isRemoteWorkspace else { return nil }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return ArtifactSidebarWorkspace(
            id: workspace.id.uuidString,
            title: workspace.title,
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true)
        )
    }

    func openArtifactFromSidebar(_ artifact: ArtifactSidebarRowSnapshot) {
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return }
        sidebarSelectionState.selection = .tabs
        switch artifact.fileKind {
        case .html:
            _ = workspace.newBrowserSurface(
                inPane: paneId,
                url: artifact.fileURL,
                focus: true,
                creationPolicy: .artifactPreview,
                omnibarVisible: false,
                bypassRemoteProxy: true
            )
        case .patch:
            if AppDelegate.shared?.openArtifactPatch(artifact.fileURL, for: tabManager) != true {
                NSSound.beep()
            }
        case .image, .video, .markdown, .text, .other, nil:
            _ = workspace.openFileSurfaces(
                inPane: paneId,
                filePaths: [artifact.fileURL.path],
                focus: true,
                reuseExisting: true
            )
        }
    }
}
