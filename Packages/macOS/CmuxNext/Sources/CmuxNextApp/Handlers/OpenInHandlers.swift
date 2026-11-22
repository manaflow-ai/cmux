import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPages

/// Open-in-app and Reveal in Finder for the focused file. Until the file
/// preview surface lands, the focused file is a browser page showing a
/// `file://` URL (the catalog gates these on `filePreviewFocused`).
enum OpenInHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("filePreviewOpenExternally", run: { try context.open(try focusedFile(context, $0)) })
        registry.bind("filePreviewRevealInFinder", run: { invocation in
            NSWorkspace.shared.revealInBackground([try focusedFile(context, invocation)])
        })
        // The focused file selected in a Files pane tab (the shared file menu's Reveal in cmux Files).
        registry.bind("filePreviewRevealInFiles", run: { invocation in
            try context.services.viewers.filesPanes.reveal(try focusedFile(context, invocation), focus: invocation.allowsViewChange)
        })
        registry.bind("filePreviewOpenWith", run: { invocation in
            let file = try focusedFile(context, invocation)
            let name = invocation["app"]?.stringValue ?? ""
            guard let app = LinkMenu.application(named: name) else { throw ActionFailure(message: MiscHandlerStrings.appNotFound(name)) }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        })
    }

    static func focusedFile(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> URL {
        // A markdown or code editor page tab (diff-host S6, S7) shows a file.
        if let id = context.scope(invocation).tab?.id.rawValue,
           let page = LocalPageTab.page(of: FilePageHandlers.providerKey(id, context.services)),
           FilePageKind.allCases.contains(where: { $0.page == page }) {
            guard let file = FilePageHandlers.file(ofTab: id, context.services) else { throw ActionFailure(message: MiscHandlerStrings.noFile) }
            return file
        }
        guard case .browser(let entry) = context.scope(invocation).pane?.currentContent,
              let url = entry.tab.state.url, url.isFileURL else { throw ActionFailure(message: MiscHandlerStrings.noFile) }
        return url
    }
}
