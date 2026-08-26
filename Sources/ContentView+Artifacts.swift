import AppKit
import CmuxArtifacts
import Foundation

extension ContentView {
    var selectedArtifactWorkspace: ArtifactSidebarWorkspace? {
        Self.artifactSidebarWorkspace(for: tabManager.selectedWorkspace)
    }

    static func artifactSidebarWorkspace(for workspace: Workspace?) -> ArtifactSidebarWorkspace? {
        guard let workspace,
              !workspace.isRemoteWorkspace else { return nil }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return ArtifactSidebarWorkspace(
            id: workspace.stableId.uuidString,
            title: workspace.title,
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true)
        )
    }

    func openArtifactFromSidebar(_ artifact: ArtifactSidebarRowSnapshot) {
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return }
        guard let projectRoot = artifact.projectRoot,
              let openedFile = ArtifactSidebarFileAccess().openedFile(
                  for: artifact.fileURL,
                  artifactRoot: projectRoot.appendingPathComponent(".cmux", isDirectory: true)
              ) else {
            NSSound.beep()
            return
        }
        let safeURL = openedFile.sourceURL
        sidebarSelectionState.selection = .tabs
        switch artifact.fileKind {
        case .html:
            let workspaceID = workspace.id
            Task { @MainActor in
                guard let previewURL = await openedFile.makeTemporaryPreviewURLAsync(
                    maximumBytes: 8 * 1024 * 1024
                ) else {
                    _ = workspace.openArtifactFileSurface(
                        inPane: paneId,
                        file: openedFile,
                        focus: true,
                        reuseExisting: true
                    )
                    return
                }
                defer { try? FileManager.default.removeItem(at: previewURL) }
                do {
                    let document = try await ArtifactHTMLPreviewDocument.load(
                        sourceURL: previewURL,
                        allowedRoot: previewURL.deletingLastPathComponent()
                    )
                    guard tabManager.selectedWorkspace?.id == workspaceID else { return }
                    _ = workspace.newBrowserSurface(
                        inPane: paneId,
                        url: document.url,
                        focus: true,
                        creationPolicy: .artifactPreview,
                        chromeVisibility: .hidden,
                        bypassRemoteProxy: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
        case .patch:
            if AppDelegate.shared?.openArtifactPatch(openedFile, for: tabManager) != true {
                NSSound.beep()
            }
        case .image, .video, .markdown, .text, .other, nil:
            _ = workspace.openArtifactFileSurface(
                inPane: paneId,
                file: openedFile,
                focus: true,
                reuseExisting: true
            )
        }
    }
}
