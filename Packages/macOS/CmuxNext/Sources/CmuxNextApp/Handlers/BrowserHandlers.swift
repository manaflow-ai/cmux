import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// Browser-category actions that act on the focused page or create browser
/// panes. Back, forward, reload, zoom, and the address bar are bound in
/// `AppActions.bindBrowser`; viewer families without a surface yet
/// (diff, Markdown, file preview) are typed-unavailable here.
enum BrowserHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindPage(into: registry, context: context)
        bindSplits(into: registry, context: context)
        bindUnavailable(context)
    }

    /// The focused (or targeted) pane's browser page, or a reported failure.
    static func page(_ context: AppActionContext, _ invocation: ActionInvocation) -> BrowserEntry? {
        if case .browser(let entry) = context.scope(invocation).pane?.currentContent { return entry }
        context.fail(HandlerStrings.noBrowser)
        return nil
    }

    private static func bindPage(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserHardReload", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            guard let webKit = entry.tab as? WebKitTab else { return context.fail(HandlerStrings.hardReloadEngine) }
            webKit.webView.reloadFromOrigin()
        })
        registry.bind("toggleBrowserDeveloperTools", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            WebInspector.toggle(entry.tab)
        })
        registry.bind("showBrowserJavaScriptConsole", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            WebInspector.showConsole(entry.tab)
        })
        registry.bind("toggleBrowserDesignMode", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            let tab = entry.tab
            Task { _ = try? await tab.evaluate("document.designMode = document.designMode === 'on' ? 'off' : 'on'") }
        })
        registry.bind("palette.browserOpenDefault", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            guard let url = entry.tab.state.url, url.scheme != "about" else { return context.fail(HandlerStrings.noPageURL) }
            NSWorkspace.shared.open(url)
        })
        registry.bind("browserTheme", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            // In-view engines follow the view's appearance for
            // prefers-color-scheme; nil follows the app.
            entry.tab.contentView.appearance = switch invocation["theme"]?.stringValue {
            case "light": NSAppearance(named: .aqua)
            case "dark": NSAppearance(named: .darkAqua)
            default: nil
            }
        })
        registry.bind("browserScreenshotPage", invoke: { invocation in
            guard let entry = page(context, invocation) else { return }
            let tab = entry.tab
            let logger = context.daemon.logger
            Task {
                do {
                    let image = try await tab.snapshot()
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
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
            registry.bind(ActionID(rawValue: id), invoke: { invocation in
                guard let pane = context.scope(invocation).pane else { return context.fail(HandlerStrings.noPane) }
                guard context.daemon.supports(DaemonCapabilities.frontendBrowserTabs) else {
                    return context.fail(HandlerStrings.frontendBrowserTabs)
                }
                guard context.connection() != nil else { return }
                let handle = pane.pane.handle
                context.daemon.send("split-browser") { connection in
                    let created = try await connection.newFrontendBrowserTab(url: "about:blank", engine: .webkit, in: handle)
                    try await connection.split(handle, direction: direction, movingTab: created.surface)
                }
            })
        }
    }

    private static func bindUnavailable(_ context: AppActionContext) {
        context.unavailable(["toggleBrowserFocusMode"], HandlerStrings.browserFocusMode)
        context.unavailable(["toggleReactGrab"], HandlerStrings.reactGrab)
        context.unavailable(["palette.browserToggleOmnibar"], HandlerStrings.omnibarToggle)
        context.unavailable(["palette.browserClearHistory"], HandlerStrings.browserHistory)
        context.unavailable(["importFromBrowser"], HandlerStrings.browserImport)
        context.unavailable(["palette.enableBrowser", "palette.disableBrowser"], HandlerStrings.browserToggle)
        context.unavailable(["openLinkInNewTab", "openLinkInDefaultBrowser"], HandlerStrings.linkTarget)
        context.unavailable(["browserScreenshotSection"], HandlerStrings.sectionScreenshot)
        context.unavailable(["browserNewProfile", "browserRenameProfile"], HandlerStrings.browserProfiles)
        context.unavailable(["saveFilePreview", "toggleFileEditorWordWrap"], HandlerStrings.filePreview)
        context.unavailable(["markdownZoomIn", "markdownZoomOut", "markdownZoomReset"], HandlerStrings.markdownViewer)
        context.unavailable(["palette.vscodeServeWebStop", "palette.vscodeServeWebRestart"], HandlerStrings.vscodeServer)
        context.unavailable([
            "openDiffViewer", "palette.openDirectoryDiffViewer",
            "diffViewerNextLine", "diffViewerPreviousLine", "diffViewerHalfPageDown", "diffViewerHalfPageUp",
            "diffViewerNextHunk", "diffViewerPreviousHunk", "diffViewerGoToBottom", "diffViewerGoToTop",
            "diffViewerSearch", "diffViewerNextFile", "diffViewerPreviousFile",
        ], HandlerStrings.diffViewer)
    }
}
