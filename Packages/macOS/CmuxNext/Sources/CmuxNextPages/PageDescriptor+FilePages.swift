public import Foundation

/// The code editor page's host commands (diff-host.md "Editor page", webviews/src/pages/editor/keys.ts).
/// `editorAction` carries a Monaco action id as `text` (keys.ts `EDITOR_ACTIONS`).
public nonisolated struct EditorPageCommand {
    public nonisolated init() {}
    public static let save = "save"
    public static let find = "find"
    public static let findNext = "findNext"
    public static let findPrevious = "findPrevious"
    public static let useSelectionForFind = "useSelectionForFind"
    public static let hideFind = "hideFind"
    public static let replace = "replace"
    public static let gotoLine = "gotoLine"
    public static let zoomIn = "zoomIn"
    public static let zoomOut = "zoomOut"
    public static let zoomReset = "zoomReset"
    public static let editorAction = "editorAction"

    public static let all: Set<String> = [
        save, find, findNext, findPrevious, useSelectionForFind, hideFind, replace, gotoLine, zoomIn, zoomOut, zoomReset,
        editorAction,
    ]

    /// The registry actions that send one of these to the focused editor tab. The shared find
    /// actions (`find`, `findNext`, ...) keep their ids; the rest are the editor's own.
    public static let forAction: [String: String] = [
        "saveFilePreview": save, "find": find, "findNext": findNext, "findPrevious": findPrevious,
        "useSelectionForFind": useSelectionForFind, "hideFind": hideFind, "fileEditorReplace": replace,
        "fileEditorGotoLine": gotoLine, "fileEditorZoomIn": zoomIn, "fileEditorZoomOut": zoomOut,
        "fileEditorZoomReset": zoomReset, "fileEditorAction": editorAction,
    ]
}

/// The markdown page's generated resources (first path components of `cmux-page://cmux.markdown/`):
/// local images of the open file's folder, the diagram libraries, and remote images the host
/// fetches (`markdown.remoteImages`) so the page CSP stays strict.
public nonisolated struct MarkdownPageResource {
    public nonisolated init() {}
    /// `__asset/<token>/<path relative to the file's folder>`.
    public static let asset = "__asset"
    /// `__lib/mermaid.js`, `__lib/vega.js`.
    public static let library = "__lib"
    /// `__image/<base64url of the http(s) URL>`.
    public static let remoteImage = "__image"
}
