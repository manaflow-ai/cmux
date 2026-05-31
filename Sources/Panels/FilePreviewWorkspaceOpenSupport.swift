import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func openFileSurfacesInFocusedPane(
        filePaths: [String],
        focus: Bool? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        guard let target = focusedBonsplitPaneForCommands() else { return [] }
        return openFileSurfaces(
            inPane: target.paneId,
            controller: target.controller,
            filePaths: filePaths,
            focus: focus,
            reuseExisting: reuseExisting
        )
    }

    @discardableResult
    func openFileSurfaces(
        inPane paneId: PaneID,
        controller targetController: BonsplitController? = nil,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        let controller = targetController ?? bonsplitController(containingPane: paneId) ?? bonsplitController
        let shouldFocusNewTabs = focus ?? (controller.focusedPaneId == paneId)
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
                        controller: controller,
                        filePath: filePath,
                        focus: shouldFocusNewTabs
                    )
                } else {
                    panel = newMarkdownSurface(
                        inPane: paneId,
                        controller: controller,
                        filePath: filePath,
                        focus: shouldFocusNewTabs,
                        targetIndex: nextIndex
                    )
                }
            } else if reuseExisting {
                panel = openOrFocusFilePreviewSurface(
                    inPane: paneId,
                    controller: controller,
                    filePath: filePath,
                    focus: shouldFocusNewTabs
                )
            } else {
                panel = newFilePreviewSurface(
                    inPane: paneId,
                    controller: controller,
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
        controller targetController: BonsplitController? = nil,
        filePaths: [String],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [FilePreviewPanel] {
        let controller = targetController ?? bonsplitController(containingPane: paneId) ?? bonsplitController
        let shouldFocusNewTabs = focus ?? (controller.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [FilePreviewPanel] = []

        for filePath in filePaths {
            let panel: FilePreviewPanel?
            if reuseExisting {
                panel = openOrFocusFilePreviewSurface(
                    inPane: paneId,
                    controller: controller,
                    filePath: filePath,
                    focus: shouldFocusNewTabs
                )
            } else {
                panel = newFilePreviewSurface(
                    inPane: paneId,
                    controller: controller,
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
