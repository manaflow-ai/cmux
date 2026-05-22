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
            let panel = openFileSurface(
                inPane: paneId,
                entry: FilePreviewDragEntry(
                    filePath: filePath,
                    displayTitle: (filePath as NSString).lastPathComponent
                ),
                focus: shouldFocusNewTabs,
                targetIndex: nextIndex,
                reuseExisting: reuseExisting
            )

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
    func openFileSurfaces(
        inPane paneId: PaneID,
        entries: [FilePreviewDragEntry],
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        reuseExisting: Bool = false
    ) -> [any Panel] {
        let shouldFocusNewTabs = focus ?? (bonsplitController.focusedPaneId == paneId)
        var nextIndex = targetIndex
        var openedPanels: [any Panel] = []

        for entry in entries {
            let panel = openFileSurface(
                inPane: paneId,
                entry: entry,
                focus: shouldFocusNewTabs,
                targetIndex: nextIndex,
                reuseExisting: reuseExisting
            )

            if let panel {
                openedPanels.append(panel)
                if let index = nextIndex {
                    nextIndex = index + 1
                }
            }
        }

        return openedPanels
    }

    private func openFileSurface(
        inPane paneId: PaneID,
        entry: FilePreviewDragEntry,
        focus: Bool,
        targetIndex: Int?,
        reuseExisting: Bool
    ) -> (any Panel)? {
        if entry.remoteSource == nil, MarkdownPanelFileLinkResolver.isMarkdownPathLike(entry.filePath) {
            if reuseExisting {
                return openOrFocusMarkdownSurface(
                    inPane: paneId,
                    filePath: entry.filePath,
                    focus: focus
                )
            }
            return newMarkdownSurface(
                inPane: paneId,
                filePath: entry.filePath,
                focus: focus,
                targetIndex: targetIndex
            )
        }

        return openFilePreviewPanel(
            inPane: paneId,
            entry: entry,
            focus: focus,
            targetIndex: targetIndex,
            reuseExisting: reuseExisting
        )
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
            let panel = openFilePreviewPanel(
                inPane: paneId,
                entry: FilePreviewDragEntry(
                    filePath: filePath,
                    displayTitle: (filePath as NSString).lastPathComponent
                ),
                focus: shouldFocusNewTabs,
                targetIndex: nextIndex,
                reuseExisting: reuseExisting
            )

            if let panel {
                openedPanels.append(panel)
                if let index = nextIndex {
                    nextIndex = index + 1
                }
            }
        }

        return openedPanels
    }

    private func openFilePreviewPanel(
        inPane paneId: PaneID,
        entry: FilePreviewDragEntry,
        focus: Bool,
        targetIndex: Int?,
        reuseExisting: Bool
    ) -> FilePreviewPanel? {
        if reuseExisting {
            return openOrFocusFilePreviewSurface(
                inPane: paneId,
                filePath: entry.filePath,
                displayPath: entry.displayPath,
                remoteSource: entry.remoteSource,
                focus: focus
            )
        }
        return newFilePreviewSurface(
            inPane: paneId,
            filePath: entry.filePath,
            displayPath: entry.displayPath,
            remoteSource: entry.remoteSource,
            focus: focus,
            targetIndex: targetIndex
        )
    }
}
