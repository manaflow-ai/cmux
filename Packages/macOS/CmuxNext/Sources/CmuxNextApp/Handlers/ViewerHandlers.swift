import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDiff
import CmuxNextPalette
import CmuxNextWindowRules

/// The viewers' open actions (R89), one path for the palette, the CLI or
/// socket, the File menu and shortcuts:
/// - `openDiffViewer`: a diff tab for the focused pane's folder; without
///   one, the cmux picker in folder mode;
/// - `palette.openDirectoryDiffViewer`: always the picker in folder mode;
/// - `openMarkdownFile` and `file.open` without a path: the picker in file
///   mode at the pane's folder (Markdown only for the first); the file
///   opens through `ViewerService.fileOpener` (the browser tab's file view
///   until the code editor page, cmux.editor, lands).
/// From the palette the pickers open in place (`actionPages`); from any
/// other entrypoint the palette opens on them.
enum ViewerHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let viewers = services.viewers
        viewers.diffPages.chooser = PickerDiffFolderChooser(viewers: viewers)
        registry.bind("openDiffViewer", run: { asked in
            guard let pane = context.paneController(asked) else { return }
            // On a chat (the shortcut, the palette, the File menu): beside it, as the header's Changes.
            let invocation = AgentBesidePlacement.besideChat(asked, in: pane)
            // `path`'s repository, else the pane's folder's; a chat's own patch (changes no git source holds) beside it (`files::open_diff`).
            let patch = invocation[AgentPaneDiffPatch.textArgument]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let ask = WindowRules.DiffAsk(patch: patch != nil, path: invocation["path"]?.stringValue, paneFolder: ViewerService.folder(of: pane),
                                          allowsViewChange: invocation.allowsViewChange, besideCaller: invocation.besideCaller)
            guard let open = WindowRules().openDiff(ask) else { throw ActionFailure(message: MiscHandlerStrings.pickerNeedsFocus) }
            if open.decision == "chatPatch", let patch {
                let opening = invocation.besideCaller ? AgentBesidePlacement.opening(invocation, in: pane, then: nil) : nil
                let chat = DiffChatPatch(text: patch, file: invocation[AgentPaneDiffPatch.fileArgument]?.stringValue, folder: open.folder)
                viewers.diffPages.open(chatPatch: chat, in: pane, focus: open.focus == true, created: opening?.created,
                                       failed: { opening?.failed($0.map { ActionWorkFailure("open diff", $0) }) })
                return
            }
            guard open.decision == "folder", let folder = open.folder else {
                if open.decision == "picker" { return context.services.palette.show(page: diffPicker(invocation, pane, viewers), relativeTo: context.activeWindow?.window) }
                throw ActionFailure(message: MiscHandlerStrings.pickerNeedsFocus)
            }
            let focus = open.focus == true
            // A chat's open (its header's Changes, an edited-files card) names a turn for Last turn.
            let turn = diffTurn(invocation), showTurn = invocation[AgentPaneDiffTurn.showArgument]?.boolValue == true
            // An agent's diff beside its chat: selected in the column right of it, or moved into a new one.
            let opening = invocation.besideCaller ? AgentBesidePlacement.opening(invocation, in: pane, then: nil) : nil
            // No repository at the pane's folder: the picker asks for one (only when the run may
            // change the view, as a person's click on the chat header's Changes may; an agent or
            // the CLI without focus gets needsFocus).
            registry.trackRollingBack("openDiffViewer", Task { @MainActor in
                // The folder is the pane's (or one named for it), so it is on the pane's machine.
                do {
                    try await viewers.openDiff(folder, turn: turn, showTurn: showTurn, in: pane, focus: focus, onPaneMachine: true,
                                               created: opening?.created, failed: { error in
                                                   opening?.failed(error.map { ActionWorkFailure("open diff", $0) })
                                               })
                } catch {
                    opening?.failed(nil)
                    // This Mac's picker cannot choose a folder of another machine (#25581): say why
                    // the pane's folder did not open (no repository, the machine is offline).
                    switch WindowRules().diffFailed(local: pane.daemon.isLocal, allowsViewChange: invocation.allowsViewChange) {
                    case "reason"?: return ActionWorkFailure("open diff", ActionFailure(message: ViewerService.reason(error)))
                    // The header's pick still opens beside the chat, as its diff would have.
                    case "picker"?: context.services.palette.show(page: diffPicker(invocation, pane, viewers), relativeTo: context.activeWindow?.window)
                    default: return backgroundPickerRefusal()
                    }
                }
                return nil
            })
        })
        // The Screenshots pane: in front only for the person's own run (it lists ~/Desktop); any other run is told it opened behind.
        registry.bindEffect("screenshots.open", effect: { services.screenshotsPage.open($0) })
        registry.bind("palette.openDirectoryDiffViewer", run: { invocation in
            guard let pane = context.paneController(invocation) else { return }
            try showPicker(diffPicker(AgentBesidePlacement.besideChat(invocation, in: pane), pane, viewers), context, invocation)
        })
        registry.bindEffect("openMarkdownFile", effect: { invocation in
            guard let pane = context.paneController(invocation) else { return .done }
            do {
                let open = WindowRules().openMarkdown(path: invocation["path"]?.stringValue, local: pane.daemon.isLocal, // `files::open_markdown`
                                                      showsChat: AgentBesidePlacement.showsChat(pane), allowsViewChange: invocation.allowsViewChange)
                switch (open?.decision, open?.place, open?.path) {
                case ("open"?, "remote"?, let path?):
                    if let reason = viewers.openFile(URL(fileURLWithPath: path), on: pane.daemon, from: pane, userChose: invocation.origin == .user) {
                        throw ActionFailure(message: reason)
                    }
                case ("open"?, "besideChat"?, let path?):
                    if let reason = viewers.openFile(URL(fileURLWithPath: path), on: nil, from: pane, userChose: true) { throw ActionFailure(message: reason) }
                case ("open"?, _, let path?):
                    viewers.openFile(URL(fileURLWithPath: path), in: pane, markdown: true)
                case ("picker"?, _, _):
                    context.services.palette.show(page: viewers.filePickerPage(for: pane, markdown: true), relativeTo: context.activeWindow?.window)
                case ("refused"?, _, let path?) where open?.refusal == "pathNotAbsolute":
                    throw ActionFailure(message: MiscHandlerStrings.pathNotAbsolute(path))
                default:
                    throw ActionFailure(message: MiscHandlerStrings.pickerNeedsFocus)
                }
                return .done
            } catch {
                return .refused(ViewerService.reason(error))
            }
        })
        // In the palette each picker is a page of the palette, pushed in place.
        services.palette.sources.actionPages["palette.openDirectoryDiffViewer"] = { [weak services] in
            guard let pane = services?.windows.active?.focusedPane, let viewers = services?.viewers else { return nil }
            return diffPicker(AgentBesidePlacement.besideChat(ActionInvocation(origin: .user), in: pane), pane, viewers)
        }
        services.palette.sources.actionPages["openMarkdownFile"] = { [weak services] in
            services?.viewers.filePickerPage(for: services?.windows.active?.focusedPane, markdown: true)
        }
        services.palette.sources.actionPages["file.open"] = { [weak services] in
            services?.viewers.filePickerPage(for: services?.windows.active?.focusedPane, markdown: false)
        }
    }

    /// The diff picker for `pane`; a folder picked for a beside run (an agent's, or one on a chat) opens beside the chat.
    static func diffPicker(_ invocation: ActionInvocation, _ pane: PaneController, _ viewers: ViewerService) -> PalettePageSpec {
        invocation.besideCaller ? viewers.diffPickerPage(for: pane, beside: { AgentBesidePlacement.opening(invocation, in: pane, then: nil) })
            : viewers.diffPickerPage(for: pane)
    }

    /// The chat turn `openDiffViewer` names (``AgentPaneDiffTurn/actionArguments``), nil without a valid pair.
    static func diffTurn(_ invocation: ActionInvocation) -> DiffTurn? {
        DiffTurn(checking: invocation[AgentPaneDiffTurn.fromArgument]?.stringValue, to: invocation[AgentPaneDiffTurn.toArgument]?.stringValue,
                 file: invocation[AgentPaneDiffTurn.fileArgument]?.stringValue)
    }

    /// `file.open` without a path (the menu, a shortcut, `cmux file open`).
    static func openFilePicker(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let pane = invocation.target == nil ? context.services.windows.active?.focusedPane : context.paneController(invocation)
        try showPicker(context.services.viewers.filePickerPage(for: pane, markdown: false), context, invocation)
    }

    /// The needsFocus refusal of a picker that background work would open (openDiffViewer at a
    /// folder with no repository): a typed refusal, so action.run answers `unavailable` with the
    /// reason, as the direct refusal does, not `daemon_error`.
    static func backgroundPickerRefusal() -> ActionWorkFailure {
        ActionWorkFailure("open diff", ActionFailure(message: MiscHandlerStrings.pickerNeedsFocus))
    }

    /// The cmux picker opens over the window only when the run may change the view (a user run, or
    /// focus requested); an agent or the CLI without focus gets needsFocus and no picker.
    private static func showPicker(_ page: @autoclosure () -> PalettePageSpec, _ context: AppActionContext,
                                   _ invocation: ActionInvocation) throws {
        guard invocation.allowsViewChange else { throw ActionFailure(message: MiscHandlerStrings.pickerNeedsFocus) }
        context.services.palette.show(page: page(), relativeTo: context.activeWindow?.window)
    }
}
