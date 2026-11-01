public import Foundation

/// The diff page's host commands on `cmux.page.command` (diff-host.md S1). The app's single key
/// dispatcher (R59) maps the `diffViewer*` actions to these; the page adds no key handling.
public nonisolated struct DiffPageCommand {
    public nonisolated init() {}
    public static let nextLine = "nextLine"
    public static let previousLine = "previousLine"
    public static let halfPageDown = "halfPageDown"
    public static let halfPageUp = "halfPageUp"
    public static let nextHunk = "nextHunk"
    public static let previousHunk = "previousHunk"
    public static let goToTop = "goToTop"
    public static let goToBottom = "goToBottom"
    public static let nextFile = "nextFile"
    public static let previousFile = "previousFile"
    /// Marks the file under the viewport viewed (or not viewed), GitHub's `v`.
    public static let toggleViewed = "toggleViewed"
    /// Collapses the file under the viewport.
    public static let collapseFile = "collapseFile"
    /// Expands the file under the viewport.
    public static let expandFile = "expandFile"

    /// Every diff command; the diff page also takes the shared ``PageNativeOp/commands``.
    public static let all: Set<String> = [
        nextLine, previousLine, halfPageDown, halfPageUp, nextHunk, previousHunk, goToTop, goToBottom,
        nextFile, previousFile, toggleViewed, collapseFile, expandFile,
    ]

    /// The page command each of the 11 `diffViewer*` registry actions sends (CmuxNextActions,
    /// BrowserActionCatalog). `diffViewerSearch` (`/`) is the shared `find` command.
    public static let forAction: [String: String] = [
        "diffViewerNextLine": nextLine, "diffViewerPreviousLine": previousLine,
        "diffViewerHalfPageDown": halfPageDown, "diffViewerHalfPageUp": halfPageUp,
        "diffViewerNextHunk": nextHunk, "diffViewerPreviousHunk": previousHunk,
        "diffViewerGoToTop": goToTop, "diffViewerGoToBottom": goToBottom,
        "diffViewerSearch": "find",
        "diffViewerNextFile": nextFile, "diffViewerPreviousFile": previousFile,
    ]
}

/// The markdown page's host commands (diff-host.md S6, webviews/src/pages/markdown/README.md): the
/// app's key dispatcher sends `save` (Cmd-S), `back` (Cmd-[), `forward` (Cmd-]), `reload` (Cmd-R),
/// `link` (Cmd-K) and the zoom commands while a markdown page has the keyboard; the page reads no
/// chord itself. The omnibar's buttons and field send `back`, `forward`, `reload` and `open`.
public nonisolated struct MarkdownPageCommand {
    public nonisolated init() {}
    public static let zoomIn = "zoomIn"
    public static let zoomOut = "zoomOut"
    public static let zoomReset = "zoomReset"
    /// Saves the document (Cmd-S, the `markdownSave` action).
    public static let save = "save"
    /// Reads the file from disk again and shows it at the same scroll (Cmd-R, `markdownReload`).
    public static let reload = "reload"
    /// Opens the absolute markdown path in `text` as the page's next history entry (typed in the omnibar).
    public static let open = "open"
    /// Inserts or edits a link at the selection (Cmd-K, `markdownLink`).
    public static let link = "link"
    /// Forgets every table's column widths in the open file (`markdownResetTableWidths`).
    public static let resetTableWidths = "resetTableWidths"
    /// Forgets the column widths of the table the user right-clicked (the page's context menu).
    public static let resetContextTableWidths = "resetContextTableWidths"

    /// The file's viewer comments changed: `text` is the new `{v, comments}` JSON (the page redraws its markers).
    public static let comments = "comments"
    /// Scrolls the document to its top (`markdownGoToTop`; a user's `g g` in a read-only page, K1).
    public static let goToTop = "goToTop"
    /// The shared find actions (Cmd-F, Cmd-G, Shift-Cmd-G, Cmd-E, Hide Find Bar), under the code
    /// editor's command names (``EditorPageCommand``): the page's find pill (markdownFind.ts).
    public static let find: Set<String> = [
        EditorPageCommand.find, EditorPageCommand.findNext, EditorPageCommand.findPrevious,
        EditorPageCommand.useSelectionForFind, EditorPageCommand.hideFind,
    ]
    public static let all: Set<String> = find.union([
        zoomIn, zoomOut, zoomReset, save, reload, open, link, resetTableWidths, resetContextTableWidths, comments, goToTop,
    ])

    /// The page command each markdown action sends; back and forward are the shared page commands.
    public static let forAction: [String: String] = [
        "markdownZoomIn": zoomIn, "markdownZoomOut": zoomOut, "markdownZoomReset": zoomReset, "markdownSave": save,
        "markdownLink": link, "markdownBack": "back", "markdownForward": "forward", "markdownReload": reload,
        "markdownResetTableWidths": resetTableWidths, "markdownGoToTop": goToTop,
    ]
}

public extension PageDescriptor {
    /// The diff page's root: the one webviews-app build (`markdown-viewer/webviews-app` in the
    /// app bundle's resources, built by scripts/build-webviews-app.sh), not a copy under this
    /// module's `Resources/pages/`. Its files live outside this module, so the app registers the
    /// root once at launch with ``registerDiffRoot(appResources:)``; the DEBUG override
    /// `CMUX_NEXT_PAGE_ROOT_cmux_diff` still wins for the page dev loop. The one place to change
    /// if the page moves.
    static let diffResource = "webviews-app"
    /// The diff page's entry html inside ``diffResource`` (named by the S3 lane).
    static let diffEntry = "diff-page.html"
    /// Where the diff page's root sits inside the app bundle's resources directory.
    static func diffRoot(inAppResources resources: URL) -> URL {
        resources.appending(path: "markdown-viewer", directoryHint: .isDirectory)
            .appending(path: diffResource, directoryHint: .isDirectory)
    }

    /// The one call the app makes at launch (diff-host S4): registers the app bundle's
    /// webviews-app directory as the `cmux.diff` root (``PageID/registerBundledRoot(_:for:)``;
    /// the first registration wins). Returns the root it registered, nil without a resources
    /// directory.
    @discardableResult
    static func registerDiffRoot(appResources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let appResources else { return nil }
        let root = diffRoot(inAppResources: appResources)
        PageID.registerBundledRoot(root, for: diff.id)
        return root
    }

    /// The one launch call for the file pages (diff-host S6, S7): registers the app bundle's
    /// webviews-app directory as the `cmux.markdown` and `cmux.editor` root (the first registration
    /// wins, as for the diff page). Returns the root, nil without a resources directory.
    @discardableResult
    static func registerFilePageRoots(appResources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let appResources else { return nil }
        let root = diffRoot(inAppResources: appResources)
        PageID.registerBundledRoot(root, for: markdown.id)
        PageID.registerBundledRoot(root, for: editor.id)
        return root
    }

    /// The classic viewer's resources (`mermaid.min.js`, `vega.min.js`, `vega-lite.min.js`), the
    /// markdown page's `__lib` libraries.
    nonisolated static func markdownLibraries(inAppResources resources: URL) -> URL {
        resources.appending(path: "markdown-viewer", directoryHint: .isDirectory)
    }

    /// The markdown page's entry html inside ``diffResource``.
    static let markdownEntry = "markdown-page.html"
    /// The code editor page's entry html inside ``diffResource``.
    static let editorEntry = "editor-page.html"

    /// The diff viewer page (diff-host.md). It fetches its patches from its own origin
    /// (`cmux-page://cmux.diff/__patch/<token>/...`, served by the page instance's
    /// ``PageDynamicResourceSource``) and compiles its highlighter's WebAssembly, so its CSP adds
    /// `connect-src cmux-page://cmux.diff` and `'wasm-unsafe-eval'`, nothing else (decision Q5).
    static let diff = PageDescriptor(
        id: "cmux.diff", resource: diffResource, namespaces: ["cmux.diff."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        commands: PageNativeOp.commands.union(DiffPageCommand.all),
        csp: PageCSP(connect: ["cmux-page://cmux.diff"], script: ["'wasm-unsafe-eval'"]),
        entry: diffEntry, dynamicPrefixes: ["__patch"],
        // Push (cmux.diff.git.push) acts on one click: not on a click that only brings the window forward.
        acceptsFirstMouse: false)

    /// The markdown page (diff-host.md S6): the strict CSP (Vega uses vega-interpreter, code
    /// highlighting Shiki's JavaScript engine) plus `'wasm-unsafe-eval'` for Ondine, the Mermaid
    /// compiler (a WebAssembly module with no imports), with images and libraries from its own origin.
    static let markdown = PageDescriptor(
        id: "cmux.markdown", resource: diffResource, namespaces: ["cmux.markdown."],
        nativeOps: [PageNativeOp.clipboardWrite],
        commands: PageNativeOp.commands.union(MarkdownPageCommand.all), csp: PageCSP(script: ["'wasm-unsafe-eval'"], inlineScript: false), entry: markdownEntry,
        dynamicPrefixes: [MarkdownPageResource.asset, MarkdownPageResource.library, MarkdownPageResource.remoteImage])

    /// The code editor page (diff-host.md "Editor page", Monaco): the strict CSP plus
    /// `'wasm-unsafe-eval'` for Shiki's Oniguruma engine; no `connect-src` and no `'unsafe-eval'`.
    /// Its worker is a same-origin module, which `script-src 'self'` allows.
    /// Its one app action is the native command palette: Monaco's own palette (F1, the context
    /// menu's Command Palette) opens it instead, so no web view has a palette of its own.
    static let editor = PageDescriptor(
        id: "cmux.editor", resource: diffResource, namespaces: ["cmux.editor."],
        nativeOps: [PageNativeOp.clipboardWrite, PageNativeOp.actionRun], actions: ["commandPalette"],
        commands: PageNativeOp.commands.union(EditorPageCommand.all),
        csp: PageCSP(script: ["'wasm-unsafe-eval'"]), entry: editorEntry)
}
