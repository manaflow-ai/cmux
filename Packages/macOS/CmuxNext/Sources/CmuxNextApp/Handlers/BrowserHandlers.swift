import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextFocus

/// Browser-category actions that act on the focused page or create browser
/// panes. Back, forward, reload, zoom, and the address bar are bound in
/// `AppActions.bindBrowser`; the diff viewer in `DiffHandlers`; viewer
/// families without a surface yet (Markdown, file preview) are unavailable here.
enum BrowserHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindPage(into: registry, context: context)
        BrowserToolbarHandlers.bind(into: registry, context: context)
        BrowserDeviceHandlers.bind(into: registry, context: context)
        bindSplits(into: registry, context: context)
        bindLinkHints(into: registry, context: context)
        BrowserEnabledToggle.bind(into: registry, context: context)
        BrowsingDataClear.bindClearHistory(registry, context: context)
        registry.bind("palette.browserToggleOmnibar", run: { invocation in try context.page(invocation).chrome.toggleOmnibar() })
    }

    private static func bindPage(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserHardReload", run: { invocation in
            guard let tab = try context.page(invocation).tab as? any BrowserCacheBypassingReload else {
                throw ActionFailure(message: MiscHandlerStrings.hardReloadEngine)
            }
            tab.reloadBypassingCache()
        })
        // Per tab, per window (FocusState.browserFocusMode): every key but
        // tier 0 goes to the page while on.
        registry.bind("toggleBrowserFocusMode", run: { invocation in
            let entry = try context.page(invocation)
            guard let pane = context.scope(invocation).pane, let window = context.services.windowController(showing: pane) else {
                throw ActionFailure(message: MiscHandlerStrings.noBrowser)
            }
            if window.focus.state.pane != pane.paneKey { window.focus.send(.focusPane(pane.paneKey, source: .intent)) }
            let tab = entry.tab.id.rawValue
            window.focus.send(.toggleBrowserFocusMode(tab: tab))
            // Entering puts the keyboard in the page (classic cmux parity): from the
            // address bar or find bar, focus mode would wait for a click otherwise.
            if window.focus.state.browserFocusMode.contains(tab) { window.focus.send(.focusTarget(.content, source: .intent)) }
        })
        // Any focused web view (WebInspectorTarget): disabled with the reason while none is.
        registry.bind("toggleBrowserDeveloperTools", unavailable: { DevToolsHandlers.noTargetReason(context) }, run: { invocation in
            let target = try DevToolsHandlers.target(invocation, context)
            WebInspector.toggle(target)
            // WebKit's inspector visibility is not observable; Chromium's is.
            if case .browser = target { (try? context.page(invocation))?.chrome.toolbarButtons.refresh() }
        })
        registry.bind("showBrowserJavaScriptConsole", unavailable: { DevToolsHandlers.noTargetReason(context) }, run: {
            WebInspector.showConsole(try DevToolsHandlers.target($0, context))
        })
        registry.bind("inspectBrowserElement", unavailable: { DevToolsHandlers.noTargetReason(context) }, run: {
            WebInspector.inspectElement(try DevToolsHandlers.target($0, context))
        })
        // Classic's Design Mode (plans/cmux-next/design-mode-DESIGN.md): highlights become cards in
        // an agent chat. The toolbar shows the mode (BrowserPageModes); a new document starts with it off.
        registry.bind("toggleBrowserDesignMode", unavailable: {
            let alreadyOn = context.services.cache.browsers.values.contains { $0.chrome.toolbarButtons.modes.designMode }
            return BrowserPageTunables.uiPointer.value || alreadyOn ? nil :
                "UI pointer picker is off. Turn it on in Debug Settings > Browser Page Loading."
        }, run: { invocation in
            let entry = try context.page(invocation)
            guard BrowserPageTunables.uiPointer.value || entry.chrome.toolbarButtons.modes.designMode else {
                throw ActionFailure(message: "UI pointer picker is off. Turn it on in Debug Settings > Browser Page Loading.")
            }
            guard let key = context.services.cache.key(of: entry.tab) else { return }
            context.services.designMode.toggle(entry, key: key)
        })
        // React Grab (classic parity): the first toggle on a document loads the pinned library into
        // the page world, later toggles flip it. A load failure says so on the page.
        registry.bind("toggleReactGrab", run: { invocation in
            let entry = try context.page(invocation)
            let tab = entry.tab, grab = context.services.reactGrab, logger = context.daemon.logger
            Task { [weak chrome = entry.chrome] in
                do {
                    try await grab.toggle(tab)
                } catch {
                    logger.error("react-grab toggle failed: \(String(describing: error), privacy: .public)")
                    chrome?.showNotice(MiscHandlerStrings.reactGrabFailed)
                }
            }
        })
        registry.bind("palette.browserOpenDefault", run: { invocation in
            guard let url = try context.page(invocation).tab.state.url, url.scheme != "about" else {
                throw ActionFailure(message: MiscHandlerStrings.noPageURL)
            }
            try context.open(url)
        })
        // WebKit follows its view's appearance, Chromium a media emulation;
        // a page that is not loaded yet gets it when it is (the toolbar's bind).
        registry.bind("browserTheme", run: { invocation in
            let entry = try context.page(invocation)
            let scheme = BrowserToolbarHandlers.colorScheme(invocation)
            entry.chrome.toolbarButtons.modes.colorScheme = scheme
            (entry.tab as? any BrowserColorSchemeApplying)?.applyColorScheme(scheme)
        })
        registry.bind("browserPrint", run: { invocation in
            guard BrowserPagePrint(try context.page(invocation).tab).run() else {
                throw ActionFailure(message: MiscHandlerStrings.printUnavailable)
            }
        })
        registry.bind("browserScreenshotPage", run: { invocation in
            let tab = try context.page(invocation).tab
            copyScreenshot(context) { try await tab.snapshot() }
        })
        // A drag over the page picks the rect (BrowserSectionOverlay; Esc
        // cancels); the page snapshot cropped to it is copied like a page.
        registry.bind("browserScreenshotSection", run: { invocation in
            let tab = try context.page(invocation).tab
            guard tab.contentView.window != nil else { throw ActionFailure(message: MiscHandlerStrings.noBrowser) }
            let overlay = BrowserSectionOverlay(over: tab.contentView)
            Task {
                guard let selection = await overlay.select() else { return }
                copyScreenshot(context) { try await selection.capture(from: tab) }
            }
        })
    }

    /// Copies the image `capture` takes to the clipboard (Screenshot Page and
    /// Screenshot Section); a failed capture is logged.
    static func copyScreenshot(_ context: AppActionContext, _ capture: @escaping @MainActor () async throws -> CGImage) {
        let logger = context.daemon.logger
        Task {
            do {
                let image = try await capture()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            } catch {
                logger.error("browser screenshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Split Browser Right/Down: a new app-rendered browser tab moved into a
    /// new split in one daemon `split {tab}` call.
    private static func bindSplits(into registry: ActionRegistry, context: AppActionContext) {
        for (id, direction) in [("splitBrowserRight", SplitDirection.right), ("splitBrowserDown", .down)] {
            registry.bindEffect(ActionID(rawValue: id), requires: DaemonCapability.frontendBrowserTabs.rawValue, daemon: context.daemon, effect: { invocation in
                try splitBrowser(from: try context.pane(invocation), direction: direction, byPerson: invocation.origin == .user,
                                 context: context)
            })
        }
    }

    /// A new app-rendered browser tab in a new split beside `pane`: the
    /// default engine at `url` in browser profile `profile`, else the
    /// new-tab page with its address bar focused; with `url` the page takes
    /// focus. The split follows the one tool-split rule (`AppServices.toolSplit`,
    /// cx-yihq), as Split Right does: refused without room, and from the docked
    /// chat a person's browser is a tab in the strip.
    ///
    /// Returns what the caller hands the registry (``ActionRegistry/settle(_:of:_:)``, or a bound handler's
    /// return): the tab open and the split are one waiting effect (`daemonEcho`: nothing shows until the daemon
    /// answers, debt until a provisional browser split exists), and its failure is reported, not only logged.
    static func splitBrowser(from pane: PaneController, direction: SplitDirection, url: URL? = nil, profile: String? = nil,
                             byPerson: Bool, context: AppActionContext) throws -> ActionEffect {
        let handle = pane.pane.handle, model = pane.pane
        let browserTabs = context.services.cache.browserTabs
        if let refusal = browserTabs.refusal(for: url) { throw ActionFailure(message: refusal) }
        switch context.services.toolSplit(from: model, edge: direction == .right ? .right : .bottom, byPerson: byPerson) {
        case .split:
            break
        case .refused(let reason):
            throw ActionFailure(message: reason)
        case .tab(let strip):
            try browserTab(in: strip, url: url, profile: profile, context: context)
            return .done
        case .besideDock(let dock):
            // Home's pinned dock alone: a browser tab aimed at it opens in a new column right of it
            // (the daemon's reroute, or PaneBrowserTabOpener's move while the dock takes tabs).
            _ = dock.newBrowserTab(url: url, profile: profile)
            return .done
        }
        if let refusal = browserTabs.refusal(in: model) { throw ActionFailure(message: refusal) }
        // The split goes to the pane's own machine (cx-2cob); `refusal` named a disconnected one.
        let daemon = context.services.daemon(for: model)
        let connection = try daemon.isLocal ? context.requireConnection() : daemon.connection ?? context.requireConnection()
        // The default engine (never refused: no engine is requested).
        guard case .open(let choice) = browserTabs.resolve(requested: nil, url: url) else { return .done }
        let intent = pane.workspace?.beginFocusIntent()
        let address = url?.absoluteString ?? context.services.newTabAddress(for: choice)
        // action-wait-allow: no provisional browser split exists yet (a tab opened in the source pane, then moved by the daemon's split); its failure is now reported.
        return .waiting(.daemonEcho) {
            do {
                let surface = try await browserTabs.open(choice, in: model, url: address, profile: profile)
                try await connection.split(handle, direction: direction, movingTab: surface)
                // The new pane takes focus (its address bar the keyboard
                // for a new-tab page). The daemon may report the tab in the
                // source pane before the move: land only in the new pane.
                pane.workspace?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, awayFrom: pane.paneKey,
                                            generation: intent)
                return nil
            } catch {
                context.daemon.logger.error("split-browser failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("split-browser", error)
            }
        }
    }

    /// A split's browser tab opened in strip pane `strip` instead (`ToolSplitDecision.tab`), focused.
    private static func browserTab(in strip: PaneController, url: URL?, profile: String?, context: AppActionContext) throws {
        let browserTabs = context.services.cache.browserTabs
        if let refusal = browserTabs.refusal(in: strip.pane) { throw ActionFailure(message: refusal) }
        guard case .open(let choice) = browserTabs.resolve(requested: nil, url: url) else { return }
        let content = strip.workspace
        if let content { PaneHandlers.focus(strip.layoutPaneID, in: content) }
        let intent = content?.beginFocusIntent()
        let address = url?.absoluteString ?? context.services.newTabAddress(for: choice)
        let model = strip.pane
        Task {
            do {
                let surface = try await browserTabs.open(choice, in: model, url: address, profile: profile)
                content?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, generation: intent)
            } catch {
                context.daemon.logger.error("split-browser tab failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `f` and `F` in a Chromium page (`LinkHintController`).
    private static func bindLinkHints(into registry: ActionRegistry, context: AppActionContext) {
        for (id, mode) in [("browserLinkHints", LinkHintSession.Mode.follow), ("browserLinkHintsNewSplit", .newSplit)] {
            registry.bind(ActionID(rawValue: id), run: { invocation in
                let pane = try context.pane(invocation)
                let entry = try context.page(invocation)
                guard let tab = entry.tab as? CEFTab else { throw ActionFailure(message: LinkHintStrings.engine) }
                let services = context.services
                let controller = services.windowController(showing: pane)
                let tabKey = services.cache.key(of: tab)
                // Links stay in the page's browser profile.
                let profile = tabKey.flatMap(services.cache.tabModel).map(services.browserProfiles.profileID(ofTab:))
                services.linkHints.start(mode, tab: tab, window: controller?.window, isFocused: { [weak controller] in
                    guard let controller, case .browserPage(_, let shown) = controller.focus.state.resolved else { return false }
                    return shown == tabKey && KeyRouter.allows(.content, focus: controller.focus.state)
                }, openInSplit: { [weak chrome = entry.chrome] url in
                    // A refused split (no room, cx-yihq) says why on the page instead of doing nothing.
                    do {
                        let effect = try splitBrowser(from: pane, direction: .right, url: url, profile: profile, byPerson: true, context: context)
                        context.registry.settle(effect, of: "browserLinkHintsNewSplit", ActionInvocation())
                    } catch let failure as ActionFailure {
                        chrome?.showNotice(failure.message)
                    } catch {}
                }, notice: { [weak chrome = entry.chrome] text in chrome?.showNotice(text) })
            })
        }
    }
}
