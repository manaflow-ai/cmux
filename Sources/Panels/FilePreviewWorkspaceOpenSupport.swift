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
        guard !isRetiredFromOwningTabManager else { return [] }
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [any Panel] = []
        defer {
            // Shared across every focused open entrypoint (sidebar click,
            // sidebar drag-drop, CLI/socket open, workspace actions): when
            // the right sidebar owns keyboard focus, hand it to the opened
            // panel so the find/shortcut router targets the document. A
            // freshly created panel's view mounts a runloop turn later and
            // cannot take first responder during activation, so this happens
            // at the coordinator level. No-op when the sidebar does not own
            // focus.
            if shouldFocusNewTabs, let firstPanel = openedPanels.first {
                handKeyboardFocusFromRightSidebarAfterFileOpen(to: firstPanel)
            }
        }

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
        guard !isRetiredFromOwningTabManager else { return [] }
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
