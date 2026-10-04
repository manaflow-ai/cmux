import AppKit
import CmuxNextActions
import CmuxNextPages

/// The diff viewer (diff-host.md S4): `openDiffViewer` (Ctrl-Shift-Cmd-G, CLI
/// `browser open-diff-viewer`) opens a diff tab for the focused pane's
/// repository through the one entry point,
/// ``DiffPageService/open(folder:source:in:focus:)``. With no folder or no
/// repository it opens the empty diff tab (``openEmpty(_:pane:focus:)``, the
/// single seam R89 may replace), as `palette.openDirectoryDiffViewer` always
/// does: the page lists recents, asks for a folder (`cmux.diff.chooseFolder`)
/// or takes a dropped one. The 11 `diffViewer*` navigation actions send their
/// page command (``DiffPageCommand/forAction``) to the focused diff tab; their
/// keys stay in the one key dispatcher, which offers them only while a diff
/// tab has the keyboard (`diffViewerFocused`).
enum DiffHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let service = context.services.diffPages
        context.services.pages.register(service)
        // R89's viewer actions open diffs through this service.
        context.services.viewers.diffViewer = service
        registry.bind("openDiffViewer", run: { invocation in
            let pane = try focusedPane(context, invocation)
            let focus = invocation.allowsViewChange
            guard let folder = folder(of: pane) else { return openEmpty(context, pane: pane, focus: focus) }
            registry.track(Task { @MainActor in
                do {
                    try await service.open(folder: URL(fileURLWithPath: folder, isDirectory: true), in: pane, focus: focus)
                } catch {
                    openEmpty(context, pane: pane, focus: focus)
                }
                return nil
            })
        })
        registry.bind("palette.openDirectoryDiffViewer", run: { invocation in
            openEmpty(context, pane: try focusedPane(context, invocation), focus: invocation.allowsViewChange)
        })
        for (action, command) in DiffPageCommand.forAction {
            registry.bind(ActionID(rawValue: action), run: { invocation in
                guard let tab = context.scope(invocation).tab, let page = service.pageView(tab.id.rawValue) else {
                    throw ActionFailure(message: DiffPageStrings.noDiffTab)
                }
                page.send(command: command)
            })
        }
    }

    /// The pane has no repository to show: the empty diff tab, where a person
    /// picks or drops a folder.
    static func openEmpty(_ context: AppActionContext, pane: PaneController, focus: Bool) {
        context.services.diffPages.openEmpty(in: pane, focus: focus)
    }

    private static func focusedPane(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> PaneController {
        guard let pane = context.scope(invocation).pane else { throw ActionFailure(message: DiffPageStrings.noFolder) }
        return pane
    }

    /// The pane's folder: the selected terminal's cwd, else the cwd of the
    /// pane's last terminal tab (a page or an agent tab has none).
    static func folder(of pane: PaneController) -> String? {
        if let cwd = pane.selectedTab?.cwd, !cwd.isEmpty { return cwd }
        return pane.pane.tabs.last { $0.kind == .pty && $0.cwd?.isEmpty == false }?.cwd
    }
}
