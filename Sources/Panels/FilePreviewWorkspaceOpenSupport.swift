import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func openFileSurfacesNavigatingTextPosition(
        inPane paneId: PaneID,
        filePath: String,
        lineNumber: Int?,
        columnNumber: Int?,
        focus: Bool? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        let openedPanels = openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: focus,
            reuseExisting: reuseExisting
        )
        // Line/column navigation applies only to plain-text file previews. The same
        // path may instead route to a Markdown render surface or an Xcode project
        // surface (see `openFileSurfaces`), neither of which has a selectable text
        // position, so for those the navigation request is intentionally a no-op.
        // Routing is covered by `searchNavigationPreservesMarkdownSurfaceRouting` and
        // `searchNavigationPreservesXcodeProjectSurfaceRouting`.
        for panel in openedPanels {
            (panel as? FilePreviewPanel)?.navigateToTextPosition(
                lineNumber: lineNumber,
                columnNumber: columnNumber
            )
        }
        return openedPanels
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
