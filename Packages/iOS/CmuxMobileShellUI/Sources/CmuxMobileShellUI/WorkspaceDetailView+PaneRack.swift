import CmuxMobileShell

extension WorkspaceDetailView {
    /// Closure-only bridge from the observable shell store into the rack subtree.
    var paneRackActions: PaneRackActions {
        PaneRackActions(
            stagePane: { paneID in
                dismissTerminalKeyboardForChrome()
                store.stagePane(paneID, in: workspace.id)
            },
            selectTab: { surfaceID, paneID in
                dismissTerminalKeyboardForChrome()
                store.selectTab(surfaceID, inPane: paneID, workspaceID: workspace.id)
            },
            createTab: { paneID in
                dismissTerminalKeyboardForChrome()
                return await store.createTab(inPane: paneID, workspaceID: workspace.id)
            },
            closeTab: { surfaceID in
                await store.closeTab(surfaceID, workspaceID: workspace.id)
            },
            setTailInterest: { surfaceIDs in
                store.paneTailStore.setInterest(surfaceIDs)
            },
            setPeekBudget: { surfaceID, rows in
                store.paneTailStore.setPeekBudget(surfaceID: surfaceID, rows: rows)
            }
        )
    }
}
