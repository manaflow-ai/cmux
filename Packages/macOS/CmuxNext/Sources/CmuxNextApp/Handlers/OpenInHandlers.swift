import AppKit
import CmuxNextActions
import CmuxNextCompatAppKit
import CmuxNextPages

/// Open-in-app and Reveal in Finder for the focused file. Until the file
/// preview surface lands, the focused file is a browser page showing a
/// `file://` URL (the catalog gates these on `filePreviewFocused`).
enum OpenInHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("filePreviewOpenExternally", requires: nil, effect: { context.open(try focusedFile(context, $0)) })
        registry.bind("filePreviewRevealInFinder", run: { invocation in
            NSWorkspace.shared.revealInBackground([try focusedFile(context, invocation)])
        })
        // The focused file selected in a Files pane tab (the shared file menu's Reveal in cmux Files).
        registry.bind("filePreviewRevealInFiles", run: { invocation in
            try context.services.viewers.filesPanes.reveal(try focusedFile(context, invocation), focus: invocation.allowsViewChange)
        })
        registry.bindEffect("filePreviewOpenWith", effect: { invocation in
            let file: URL
            do { file = try focusedFile(context, invocation) } catch { return .refused((error as? ActionFailure)?.message ?? error.localizedDescription) }
            let name = invocation["app"]?.stringValue ?? ""
            let queries = context.services.workspaceQueries
            // action-wait-allow: the app a name means is known only when Launch Services answers on the system lane; then it opens.
            return .waiting(.externalProcess) {
                guard let app = (try? await queries.value(LinkMenu.application(named: name), priority: .userBlocking)) ?? nil else {
                    return ActionWorkFailure(MiscHandlerStrings.appNotFound(name))
                }
                NSWorkspace.shared.openInBackground([file], withApplicationAt: app)
                return nil
            }
        })
    }

    static func focusedFile(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> URL {
        // A markdown or code editor page tab (diff-host S6, S7) shows a file.
        if let key = context.scope(invocation).tab?.id.rawValue, let file = FilePageHandlers.file(ofTab: key, context.services) {
            return file
        }
        guard case .browser(let entry) = context.scope(invocation).pane?.currentContent,
              let url = entry.tab.state.url, url.isFileURL else { throw ActionFailure(message: MiscHandlerStrings.noFile) }
        return url
    }
}
