import Bonsplit
import Foundation

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
            switch LocalFileSurfaceRouting.kind(forFilePath: filePath) {
            case .project:
                if reuseExisting {
                    panel = openOrFocusProjectSurface(
                        inPane: paneId,
                        projectPath: filePath,
                        focus: shouldFocusNewTabs
                    )
                } else {
                    panel = newProjectSurface(
                        inPane: paneId,
                        projectPath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                }
            case .markdown:
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
            case .filePreview:
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
