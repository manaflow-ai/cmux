import AppKit
import CmuxNextActions
import CmuxNextPalette

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
        registry.bind("openDiffViewer", run: { invocation in
            guard let pane = context.paneController(invocation) else { return }
            if let folder = ViewerService.folder(of: pane) {
                try viewers.openDiff(folder, in: pane, focus: invocation.allowsViewChange)
            } else {
                showPicker(viewers.diffPickerPage(for: pane), context)
            }
        })
        registry.bind("palette.openDirectoryDiffViewer", run: { invocation in
            guard let pane = context.paneController(invocation) else { return }
            showPicker(viewers.diffPickerPage(for: pane), context)
        })
        registry.bind("openMarkdownFile", run: { invocation in
            let pane = context.paneController(invocation)
            if let path = invocation["path"]?.stringValue, !path.isEmpty {
                viewers.openFile(URL(fileURLWithPath: path), in: pane, markdown: true)
            } else {
                showPicker(viewers.filePickerPage(for: pane, markdown: true), context)
            }
        })
        // In the palette each picker is a page of the palette, pushed in place.
        services.palette.sources.actionPages["palette.openDirectoryDiffViewer"] = { [weak services] in
            guard let pane = services?.windows.active?.focusedPane else { return nil }
            return services?.viewers.diffPickerPage(for: pane)
        }
        services.palette.sources.actionPages["openMarkdownFile"] = { [weak services] in
            services?.viewers.filePickerPage(for: services?.windows.active?.focusedPane, markdown: true)
        }
        services.palette.sources.actionPages["file.open"] = { [weak services] in
            services?.viewers.filePickerPage(for: services?.windows.active?.focusedPane, markdown: false)
        }
    }

    /// `file.open` without a path (the menu, a shortcut, `cmux file open`).
    static func openFilePicker(_ invocation: ActionInvocation, context: AppActionContext) {
        let pane = invocation.target == nil ? context.services.windows.active?.focusedPane : context.paneController(invocation)
        showPicker(context.services.viewers.filePickerPage(for: pane, markdown: false), context)
    }

    private static func showPicker(_ page: PalettePageSpec, _ context: AppActionContext) {
        context.services.palette.show(page: page, relativeTo: context.activeWindow?.window)
    }
}
