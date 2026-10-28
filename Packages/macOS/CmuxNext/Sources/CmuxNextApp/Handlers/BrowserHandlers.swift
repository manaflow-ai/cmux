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
            // The page script is awaited off the action's turn; a failure's notice is one task of the run's completion.
            registry.trackWork(owner: "BrowserHandlers.toggleReactGrab", on: context.services.mainWork, tracked: false) {
                try await grab.toggle(tab)
            } then: { [weak chrome = entry.chrome] result in
                if case .failure(let error) = result {
                    logger.error("react-grab toggle failed: \(String(describing: error), privacy: .public)")
                    chrome?.showNotice(MiscHandlerStrings.reactGrabFailed)
                }
                return nil
            }
        })
        registry.bindEffect("palette.browserOpenDefault", requires: nil, effect: { invocation in
            guard let url = try context.page(invocation).tab.state.url, url.scheme != "about" else {
                throw ActionFailure(message: MiscHandlerStrings.noPageURL)
            }
            return context.open(url)
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
            let overlay = BrowserSectionOverlay(over: tab.contentView, pointerFrames: context.services.dragFrameInput)
            copyScreenshot(context) {
                // Esc cancels the drag: nothing is copied or logged.
                guard let selection = await overlay.select() else { throw CancellationError() }
                return try await selection.capture(from: tab)
            }
        })
    }

    /// Copies the image `capture` takes to the clipboard (Screenshot Page and
    /// Screenshot Section); a failed capture is logged. The capture is awaited off
    /// the action's turn; the clipboard write is one task of the run's completion.
    static func copyScreenshot(_ context: AppActionContext, _ capture: @escaping @MainActor () async throws -> CGImage) {
        let logger = context.daemon.logger
        context.registry.trackWork(owner: "BrowserHandlers.copyScreenshot", on: context.services.mainWork, tracked: false) {
            try await capture()
        } then: { result in
            switch result {
            case .success(let image):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            case .failure(is CancellationError):
                break
            case .failure(let error):
                logger.error("browser screenshot failed: \(String(describing: error), privacy: .public)")
            }
            return nil
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
    /// return): the new pane and its stand-in tab show in this turn (a split intent); the tab open and the
    /// move to the split are the effect's send, and a failure takes the pane back and is reported.
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
        // The split goes to the pane's own machine (cx-2cob; `refusal` named a disconnected one).
        let daemon = context.services.daemon(for: model)
        let connection = try daemon.isLocal ? context.requireConnection() : daemon.connection ?? context.requireConnection()
        // The default engine (never refused: no engine is requested).
        guard case .open(let choice) = browserTabs.resolve(requested: nil, url: url) else { return .done }
        let address = url?.absoluteString ?? context.services.newTabAddress(for: choice)
        let open: @MainActor () async throws -> SurfaceID = { try await browserTabs.open(choice, in: model, url: address, profile: profile) }
        let target: FocusState.Target = url == nil ? .addressBar : .content
        // A stand-in as PaneBrowserTabOpener.standInApplies allows it: this Mac's connected daemon, no
        // incognito window (another machine's page and an incognito record are made only from the daemon's tab).
        guard daemon.isLocal, daemon.connection != nil, !browserTabs.isIncognitoPane(model) else {
            return splitWithoutStandIn(pane, direction, target: target, open: open, connection: connection, context: context)
        }
        let record = ProvisionalTab()
        let standIn = (record, record.browser(url: address, engine: choice.engine.rawValue, profile: browserTabs.resolveProfile(model, profile)))
        return splitWithStandIn(pane, direction, standIn: standIn, chromium: choice.engine == .cef, target: target, open: open,
                                connection: connection, context: context)
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
        // The open is awaited off the action's turn; the focus it expects is one task of the run's completion.
        context.registry.trackWork(owner: "BrowserHandlers.splitBrowserTab", on: context.services.mainWork, tracked: false) {
            try await browserTabs.open(choice, in: model, url: address, profile: profile)
        } then: { result in
            switch result {
            case .success(let surface):
                content?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, generation: intent)
            case .failure(let error):
                context.daemon.logger.error("split-browser tab failed: \(String(describing: error), privacy: .public)")
            }
            return nil
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


// MARK: Split Browser's sends

extension BrowserHandlers {
    /// The chain's even sizing, shown in this turn (one spring for the split, as Cmd-D's); call the result with
    /// whether the split landed.
    private static func showSizing(_ pane: PaneController, _ direction: SplitDirection) -> (@MainActor (Bool) -> Void) {
        let layout = pane.workspace?.layoutModel
        let changes = layout?.splitSizingChanges(splitting: pane.layoutPaneID, axis: direction == .right ? .horizontal : .vertical) ?? []
        guard let layout, !changes.isEmpty else { return { _ in } }
        let shown = layout.showSplitSizing(changes)
        return { landed in if landed { layout.commitSplitSizing(shown) } else { layout.cancelSplitSizing(shown) } }
    }

    /// `open` opens the tab in `pane` (`new-frontend-browser-tab`) and returns its surface.
    /// The new pane shows in this turn holding `standIn` with its page (its address bar focused for a New Tab
    /// page), as Cmd-D's provisional pane does (PaneHandlers.split). The registry then sends the open (its tab
    /// held out of sight in `pane`, ProvisionalTab.held) and the move; the daemon's pane takes the provisional
    /// pane's place in the apply that places it, and its tab the stand-in's page (TabContentCache.standInSuccessors).
    /// A failure takes the pane back and is reported.
    private static func splitWithStandIn(_ pane: PaneController, _ direction: SplitDirection, standIn: (tab: ProvisionalTab, record: TabSnapshot),
                                         chromium: Bool, target: FocusState.Target, open: @escaping @MainActor () async throws -> SurfaceID,
                                         connection: DaemonConnection, context: AppActionContext) -> ActionEffect {
        let services = context.services, cache = services.cache, input = services.keyRouter.creationInputCoordinator, store = pane.daemon.store
        let content = pane.workspace, intent = content?.beginFocusIntent(), window = content == nil ? nil : pane.view.window
        let transaction = ClientTransactionID.generate(), key = standIn.tab.id
        // create.tab: from this turn to the page's first contentful paint; the stand-in shows in this turn.
        if let timing = cache.createTabs.begin(chromium ? .chromium : .webkit, shows: pane.showsNewTabs) { cache.createTabs.expect(timing, tab: key, standIn: true) }
        let sizing = showSizing(pane, direction)
        store.intend(.splitPane(pane: pane.pane.handle, direction: direction, ratio: 0.5, provisional: ProvisionalPane(holding: standIn.record)),
                     transaction: transaction)
        content?.focus.expect(.tab(key), target: target, generation: intent)
        let keys = input.begin(in: window, generation: intent, tab: key)
        content?.applyCurrent() // laid out and mounted in this turn: the pane draws in the key's frame
        let logger = context.daemon.logger
        return .applied(ActionConfirmation(send: {
            var landed = false, opened: SurfaceID?
            defer { input.resolve(keys, landed: landed, in: window) }
            do {
                let surface = try await open()
                opened = surface
                ProvisionalTab.held(transaction, surface: surface, in: store)
                // The person closed the pane first: the hold's close takes the tab, and the intent
                // leaves once that close committed (as NewBrowserTabCommand settles a cancelled tab).
                if store.creations.wasCancelled(transaction) {
                    sizing(false)
                    await settle(transaction, in: store, after: connection)
                    return nil
                }
                cache.standInSuccessors[surface] = key
                // Focus waits for the tab away from `pane` from now, before the move's events: it never lands in `pane`.
                content?.expectFocus(on: surface, target: target, awayFrom: pane.paneKey, generation: intent)
                try await connection.split(pane.pane.handle, direction: direction, movingTab: surface)
                await settle(transaction, in: store, after: connection)
                landed = !store.creations.wasCancelled(transaction)
                sizing(landed)
                return nil
            } catch {
                // The provisional pane goes; a tab the open made stays in `pane`, with the stand-in's page.
                sizing(false)
                store.rejectIntent(transaction)
                if opened == nil { cache.release(key) }
                logger.error("split-browser failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("split-browser", error)
            }
        }))
    }

    /// Another machine's pane or an incognito window: no stand-in (its page is made only from the daemon's
    /// tab: the machine's notice and route, the incognito record), so what shows in this turn is the chain's
    /// even sizing; the pane and its tab show when the move lands. A failure takes the sizing back and is reported.
    private static func splitWithoutStandIn(_ pane: PaneController, _ direction: SplitDirection, target: FocusState.Target,
                                            open: @escaping @MainActor () async throws -> SurfaceID, connection: DaemonConnection, context: AppActionContext) -> ActionEffect {
        let content = pane.workspace, intent = content?.beginFocusIntent(), sizing = showSizing(pane, direction), logger = context.daemon.logger
        return .applied(ActionConfirmation(send: {
            do {
                let surface = try await open()
                // The daemon may report the tab in `pane` before the move: focus lands only in the new pane.
                content?.expectFocus(on: surface, target: target, awayFrom: pane.paneKey, generation: intent)
                try await connection.split(pane.pane.handle, direction: direction, movingTab: surface)
                sizing(true)
                return nil
            } catch {
                sizing(false)
                logger.error("split-browser failed: \(String(describing: error), privacy: .public)")
                return ActionWorkFailure("split-browser", error)
            }
        }))
    }

    /// The split's intent settles at the event sequence after the reply (every event of the open and the move).
    private static func settle(_ transaction: ClientTransactionID, in store: DaemonStore, after connection: DaemonConnection) async {
        if let sequence = await connection.eventSequence() { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
    }
}
