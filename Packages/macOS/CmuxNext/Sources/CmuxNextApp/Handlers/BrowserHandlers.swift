import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// Browser-category actions that act on the focused page or create browser
/// panes. Back, forward, reload, zoom, and the address bar are bound in
/// `AppActions.bindBrowser`; viewer families without a surface yet
/// (diff, Markdown, file preview) are unavailable here.
enum BrowserHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindPage(into: registry, context: context)
        bindSplits(into: registry, context: context)
        bindUnavailable(registry)
    }

    private static func bindPage(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserHardReload", run: { invocation in
            guard let webKit = try context.page(invocation).tab as? WebKitTab else {
                throw ActionFailure(message: HandlerStrings.hardReloadEngine)
            }
            webKit.webView.reloadFromOrigin()
        })
        registry.bind("toggleBrowserDeveloperTools", run: { WebInspector.toggle(try context.page($0).tab) })
        registry.bind("showBrowserJavaScriptConsole", run: { WebInspector.showConsole(try context.page($0).tab) })
        registry.bind("toggleBrowserDesignMode", run: { invocation in
            let tab = try context.page(invocation).tab
            Task { _ = try? await tab.evaluate("document.designMode = document.designMode === 'on' ? 'off' : 'on'") }
        })
        registry.bind("palette.browserOpenDefault", run: { invocation in
            guard let url = try context.page(invocation).tab.state.url, url.scheme != "about" else {
                throw ActionFailure(message: HandlerStrings.noPageURL)
            }
            try context.open(url)
        })
        registry.bind("browserTheme", run: { invocation in
            // In-view engines follow the view's appearance for
            // prefers-color-scheme; nil follows the app.
            let view = try context.page(invocation).tab.contentView
            view.appearance = switch invocation["theme"]?.stringValue {
            case "light": NSAppearance(named: .aqua)
            case "dark": NSAppearance(named: .darkAqua)
            default: nil
            }
        })
        registry.bind("browserScreenshotPage", run: { invocation in
            let tab = try context.page(invocation).tab
            let logger = context.daemon.logger
            Task {
                do {
                    let image = try await tab.snapshot()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                } catch {
                    logger.error("browser screenshot failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
    }

    /// Split Browser Right/Down: a new app-rendered browser tab moved into a
    /// new split in one daemon `split {tab}` call.
    private static func bindSplits(into registry: ActionRegistry, context: AppActionContext) {
        for (id, direction) in [("splitBrowserRight", SplitDirection.right), ("splitBrowserDown", .down)] {
            registry.bind(ActionID(rawValue: id), requires: DaemonCapabilities.frontendBrowserTabs, daemon: context.daemon, run: { invocation in
                let handle = try context.pane(invocation).pane.handle
                _ = try context.connection()
                context.daemon.send("split-browser") { connection in
                    let created = try await connection.newFrontendBrowserTab(url: "about:blank", engine: .webkit, in: handle)
                    try await connection.split(handle, direction: direction, movingTab: created.surface)
                }
            })
        }
    }

    private static func bindUnavailable(_ registry: ActionRegistry) {
        func unavailable(_ ids: [ActionID], _ reason: String) { registry.bindUnavailable(ids, ActionFailure(message: reason)) }
        unavailable(["toggleBrowserFocusMode"], HandlerStrings.browserFocusMode)
        unavailable(["toggleReactGrab"], HandlerStrings.reactGrab)
        unavailable(["palette.browserToggleOmnibar"], HandlerStrings.omnibarToggle)
        unavailable(["palette.browserClearHistory"], HandlerStrings.browserHistory)
        unavailable(["importFromBrowser"], HandlerStrings.browserImport)
        unavailable(["palette.enableBrowser", "palette.disableBrowser"], HandlerStrings.browserToggle)
        unavailable(["openLinkInNewTab", "openLinkInDefaultBrowser"], HandlerStrings.linkTarget)
        unavailable(["browserScreenshotSection"], HandlerStrings.sectionScreenshot)
        unavailable(["browserNewProfile", "browserRenameProfile"], HandlerStrings.browserProfiles)
        unavailable(["saveFilePreview", "toggleFileEditorWordWrap"], HandlerStrings.filePreview)
        unavailable(["markdownZoomIn", "markdownZoomOut", "markdownZoomReset"], HandlerStrings.markdownViewer)
        unavailable(["palette.vscodeServeWebStop", "palette.vscodeServeWebRestart"], HandlerStrings.vscodeServer)
        unavailable([
            "openDiffViewer", "palette.openDirectoryDiffViewer",
            "diffViewerNextLine", "diffViewerPreviousLine", "diffViewerHalfPageDown", "diffViewerHalfPageUp",
            "diffViewerNextHunk", "diffViewerPreviousHunk", "diffViewerGoToBottom", "diffViewerGoToTop",
            "diffViewerSearch", "diffViewerNextFile", "diffViewerPreviousFile",
        ], HandlerStrings.diffViewer)
    }
}
