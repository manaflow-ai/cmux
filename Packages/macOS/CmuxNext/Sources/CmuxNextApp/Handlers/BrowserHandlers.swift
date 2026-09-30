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
                throw ActionFailure(message: MiscHandlerStrings.hardReloadEngine)
            }
            webKit.webView.reloadFromOrigin()
        })
        // Per tab, per window (FocusState.browserFocusMode): every key but
        // tier 0 goes to the page while on.
        registry.bind("toggleBrowserFocusMode", run: { invocation in
            let entry = try context.page(invocation)
            guard let pane = context.scope(invocation).pane, let window = context.services.windowController(showing: pane) else {
                throw ActionFailure(message: MiscHandlerStrings.noBrowser)
            }
            if window.focus.state.pane != pane.paneKey { window.focus.send(.focusPane(pane.paneKey, source: .intent)) }
            window.focus.send(.toggleBrowserFocusMode(tab: entry.tab.id.rawValue))
        })
        registry.bind("toggleBrowserDeveloperTools", run: { WebInspector.toggle(try context.page($0).tab) })
        registry.bind("showBrowserJavaScriptConsole", run: { WebInspector.showConsole(try context.page($0).tab) })
        registry.bind("inspectBrowserElement", run: { WebInspector.inspectElement(try context.page($0).tab) })
        registry.bind("toggleBrowserDesignMode", run: { invocation in
            let tab = try context.page(invocation).tab
            Task { _ = try? await tab.evaluate("document.designMode = document.designMode === 'on' ? 'off' : 'on'") }
        })
        registry.bind("palette.browserOpenDefault", run: { invocation in
            guard let url = try context.page(invocation).tab.state.url, url.scheme != "about" else {
                throw ActionFailure(message: MiscHandlerStrings.noPageURL)
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
                let pane = try context.pane(invocation)
                let handle = pane.pane.handle
                let connection = try context.requireConnection()
                let browserTabs = context.services.cache.browserTabs!
                // The default engine (never refused: no engine is requested).
                guard case .open(let choice) = browserTabs.resolve(requested: nil) else { return }
                let intent = pane.workspace?.beginFocusIntent()
                Task {
                    do {
                        let surface = try await browserTabs.open(choice, in: handle, url: "about:blank")
                        try await connection.split(handle, direction: direction, movingTab: surface)
                        // The new pane takes focus and its address bar the keyboard.
                        // The daemon may report the tab in the source pane
                        // before the move: land only in the new pane.
                        pane.workspace?.expectFocus(on: surface, target: .addressBar, awayFrom: pane.paneKey, generation: intent)
                    } catch {
                        context.daemon.logger.error("split-browser failed: \(String(describing: error), privacy: .public)")
                    }
                }
            })
        }
    }

    private static func bindUnavailable(_ registry: ActionRegistry) {
        func unavailable(_ ids: [ActionID], _ reason: String) { registry.bindUnavailable(ids, ActionFailure(message: reason)) }
        unavailable(["toggleReactGrab"], MiscHandlerStrings.reactGrab)
        unavailable(["palette.browserToggleOmnibar"], MiscHandlerStrings.omnibarToggle)
        unavailable(["palette.browserClearHistory"], MiscHandlerStrings.browserHistory)
        unavailable(["importFromBrowser"], MiscHandlerStrings.browserImport)
        unavailable(["palette.enableBrowser", "palette.disableBrowser"], MiscHandlerStrings.browserToggle)
        unavailable(["openLinkInNewTab", "openLinkInDefaultBrowser"], MiscHandlerStrings.linkTarget)
        unavailable(["browserScreenshotSection"], MiscHandlerStrings.sectionScreenshot)
        unavailable(["browserNewProfile", "browserRenameProfile"], MiscHandlerStrings.browserProfiles)
        unavailable(["saveFilePreview", "toggleFileEditorWordWrap"], MiscHandlerStrings.filePreview)
        unavailable(["markdownZoomIn", "markdownZoomOut", "markdownZoomReset"], MiscHandlerStrings.markdownViewer)
        unavailable(["palette.vscodeServeWebStop", "palette.vscodeServeWebRestart"], MiscHandlerStrings.vscodeServer)
        unavailable([
            "openDiffViewer", "palette.openDirectoryDiffViewer",
            "diffViewerNextLine", "diffViewerPreviousLine", "diffViewerHalfPageDown", "diffViewerHalfPageUp",
            "diffViewerNextHunk", "diffViewerPreviousHunk", "diffViewerGoToBottom", "diffViewerGoToTop",
            "diffViewerSearch", "diffViewerNextFile", "diffViewerPreviousFile",
        ], MiscHandlerStrings.diffViewer)
    }
}
