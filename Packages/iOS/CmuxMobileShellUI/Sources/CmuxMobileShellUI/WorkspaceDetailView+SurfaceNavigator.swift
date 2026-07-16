#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import SwiftUI

/// The surface navigator: the strip/pager/map's snapshot, action bundle, page
/// content, and settle handling. This file is the ONLY bridge between the
/// navigator views (pure value snapshots) and the store.
extension WorkspaceDetailView {
    var navigatorSnapshot: SurfaceNavigatorSnapshot {
        SurfaceNavigatorSnapshot.build(
            workspace: workspace,
            selectedTabID: navigatorDisplayTabID,
            sessions: visibleChatSessions
        )
    }

    /// The tab the pager shows: a non-terminal tab being previewed, else the
    /// store's terminal selection.
    var navigatorDisplayTabID: MobileTerminalPreview.ID? {
        if let previewedNonTerminalTabID,
           navigatorLayout.orderedTabs.contains(where: { $0.id == previewedNonTerminalTabID }) {
            return previewedNonTerminalTabID
        }
        return selectedTerminal?.id
    }

    var navigatorLayout: MobileWorkspacePaneLayout {
        workspace.paneLayout ?? .singlePane(terminals: workspace.terminals)
    }

    var navigatorActions: SurfaceNavigatorActions {
        SurfaceNavigatorActions(
            selectTab: { navigatorSelectTab($0) },
            closeTab: { navigatorCloseTab($0) },
            newTab: { navigatorNewTab(inPane: $0) },
            openMap: { presentWorkspaceMap() }
        )
    }

    /// Chip tap / map tap. Terminal tabs route through the same
    /// chrome-selection path the old picker used (autofocus-suppressed,
    /// closes the phone browser overlay); non-terminal tabs page to their
    /// placeholder without touching the store's terminal selection.
    func navigatorSelectTab(_ id: MobileTerminalPreview.ID) {
        let kind = navigatorLayout.orderedTabs.first { $0.id == id }?.kind ?? .terminal
        guard kind == .terminal else {
            previewedNonTerminalTabID = id
            return
        }
        previewedNonTerminalTabID = nil
        dismissTerminalKeyboardForChrome()
        browserStore.closeBrowser(for: workspace.id.rawValue)
        store.selectTerminalFromChrome(id)
    }

    func navigatorCloseTab(_ id: MobileTerminalPreview.ID) {
        if previewedNonTerminalTabID == id {
            previewedNonTerminalTabID = nil
        }
        store.closeTerminal(workspaceID: workspace.id, terminalID: id)
    }

    func navigatorNewTab(inPane paneID: MobileWorkspacePaneLayout.Pane.ID?) {
        dismissTerminalKeyboardForChrome()
        previewedNonTerminalTabID = nil
        browserStore.closeBrowser(for: workspace.id.rawValue)
        store.createTerminal(in: workspace.id, paneID: paneID)
    }

    func presentWorkspaceMap() {
        dismissTerminalKeyboardForChrome()
        withAnimation(.snappy(duration: 0.3)) {
            isWorkspaceMapPresented = true
        }
    }

    /// A swipe settled on a page. Terminal pages become the selected terminal
    /// (keyboard follows if a terminal held it); non-terminal pages become a
    /// local preview.
    func navigatorPageSettled(_ pageID: String) {
        let id = MobileTerminalPreview.ID(rawValue: pageID)
        let kind = navigatorLayout.orderedTabs.first { $0.id == id }?.kind ?? .terminal
        guard kind == .terminal else {
            previewedNonTerminalTabID = id
            return
        }
        previewedNonTerminalTabID = nil
        // Capture BEFORE the selection swap: whether a terminal owned the
        // keyboard when the swipe began deciding where it should land.
        let keyboardOwner = GhosttySurfaceView.activeInputHostSurfaceID
        store.selectTerminalFromChrome(id)
        if let keyboardOwner, keyboardOwner != pageID {
            // Hand the keyboard to the incoming surface so keystrokes never
            // route to the page the user just swiped away from.
            GhosttySurfaceView.focusInput(surfaceID: pageID)
        }
    }

    var navigatorPageIDs: [String] {
        navigatorSnapshot.orderedChips.map(\.id.rawValue)
    }

    @ViewBuilder
    func surfacePage(id pageID: String, context: SurfacePageContext) -> some View {
        let id = MobileTerminalPreview.ID(rawValue: pageID)
        let tab = navigatorLayout.orderedTabs.first { $0.id == id }
        switch tab?.kind ?? .terminal {
        case .terminal:
            if context.isMounted {
                terminalArtifactSurface(terminalID: pageID, isCurrent: context.isCurrent)
            } else {
                TerminalPalette.background
            }
        case .browser, .other:
            SurfacePlaceholderPage(
                title: tab?.title ?? "",
                kind: tab?.kind ?? .other
            )
        }
    }
}
#endif
