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

/// The markdown page's host commands (the `markdownZoom*` actions, diff-host.md S6).
public nonisolated struct MarkdownPageCommand {
    public nonisolated init() {}
    public static let zoomIn = "zoomIn"
    public static let zoomOut = "zoomOut"
    public static let zoomReset = "zoomReset"

    public static let all: Set<String> = [zoomIn, zoomOut, zoomReset]

    public static let forAction: [String: String] = [
        "markdownZoomIn": zoomIn, "markdownZoomOut": zoomOut, "markdownZoomReset": zoomReset,
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

    /// The markdown page's directory under `Resources/pages/` (S6).
    static let markdownResource = "markdown"

    /// The diff viewer page (diff-host.md). It fetches its patches from its own origin
    /// (`cmux-page://cmux.diff/__patch/<token>/...`, served by the page instance's
    /// ``PageDynamicResourceSource``) and compiles its highlighter's WebAssembly, so its CSP adds
    /// `connect-src cmux-page://cmux.diff` and `'wasm-unsafe-eval'`, nothing else (decision Q5).
    static let diff = PageDescriptor(
        id: "cmux.diff", resource: diffResource, namespaces: ["cmux.diff."],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        commands: PageNativeOp.commands.union(DiffPageCommand.all),
        csp: PageCSP(connect: ["cmux-page://cmux.diff"], script: ["'wasm-unsafe-eval'"]),
        entry: diffEntry, dynamicPrefixes: ["__patch"])

    /// The markdown viewer page (diff-host.md S6). Strict CSP for now (see the S1 review note:
    /// its Vega charts need evaluated code; S6 decides).
    static let markdown = PageDescriptor(
        id: "cmux.markdown", resource: markdownResource, namespaces: ["cmux.markdown."],
        nativeOps: [PageNativeOp.clipboardWrite],
        commands: PageNativeOp.commands.union(MarkdownPageCommand.all))
}
