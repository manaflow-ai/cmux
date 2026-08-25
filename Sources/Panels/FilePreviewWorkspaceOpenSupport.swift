import Bonsplit
import Foundation

extension Workspace {
    /// Opens an artifact through its already-validated descriptor. The panel
    /// retains that descriptor and reads `/dev/fd`, so a pathname replacement
    /// cannot redirect the preview after this method returns.
    @discardableResult
    func openArtifactFileSurface(
        inPane paneId: PaneID,
        file: ArtifactSidebarFileAccess.OpenedFile,
        focus: Bool = true,
        reuseExisting: Bool = false
    ) -> (any Panel)? {
        let filePath = file.sourceURL.path
        if reuseExisting {
            let canonical = (filePath as NSString).resolvingSymlinksInPath
            for (existingID, panel) in panels {
                let existingPath: String?
                if let markdown = panel as? MarkdownPanel {
                    existingPath = markdown.filePath
                } else if let preview = panel as? FilePreviewPanel {
                    existingPath = preview.filePath
                } else {
                    existingPath = nil
                }
                let isArtifactBacked: Bool
                if let markdown = panel as? MarkdownPanel {
                    isArtifactBacked = markdown.isReadOnly
                } else if let preview = panel as? FilePreviewPanel {
                    isArtifactBacked = preview.isReadOnly
                } else {
                    isArtifactBacked = false
                }
                guard isArtifactBacked,
                      let existingPath,
                      (existingPath as NSString).resolvingSymlinksInPath == canonical else {
                    continue
                }
                if focus {
                    focusPanel(existingID)
                }
                return panel
            }
        }

        if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
            return newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: focus,
                artifactFile: file
            )
        }
        return newFilePreviewSurface(
            inPane: paneId,
            filePath: filePath,
            focus: focus,
            artifactFile: file
        )
    }

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
