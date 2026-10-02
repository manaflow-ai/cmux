public import AppKit
import Foundation

extension CEFTab {
    /// Translates shim events into `BrowserNavigationEvent`s.
    ///
    /// CEF order for a navigation: OnLoadingStateChange(loading) ->
    /// OnLoadStart (after commit) -> OnLoadEnd or OnLoadError ->
    /// OnLoadingStateChange(!loading). Same-document navigations only change
    /// the address and the loading state.
    func handle(_ event: CEFShimEvent) {
        switch event {
        case .loadingState(_, let loading, let back, let forward):
            machine.apply(.historyChanged(canGoBack: back, canGoForward: forward))
            if loading, !state.isLoading {
                let id = makeNavigationID()
                navigation = id
                capturesTitleBeforeCommit = true
                machine.apply(.started(id, url: nil))
            } else if !loading, state.isLoading, let navigation {
                machine.apply(.finished(navigation))
            }
            if !loading { clearTitleBeforeCommit() }
        case .loadStart(_, let url):
            if navigation == nil || !state.isLoading {
                let id = makeNavigationID()
                navigation = id
                machine.apply(.started(id, url: URL(string: url)))
            }
            if let navigation { machine.apply(.committed(navigation, url: URL(string: url))) }
            if let title = titleBeforeCommit { machine.apply(.titleChanged(title)) }
            clearTitleBeforeCommit()
            committedURL = URL(string: url)
            pageInfoDocumentCommitted(URL(string: url))
            if PageBackground.isRealPage(URL(string: url)) { reachedFirstRealPage() }
        case .loadEnd:
            if let navigation { machine.apply(.finished(navigation)) }
            // Mixed content shows up while the page loads subresources.
            syncSecurityFromChromium()
            // Extensions finish loading after the first window exists and
            // badges are per page; refresh cheaply on each document load.
            refreshExtensionActions()
        case .loadError(_, let code, let text, let url):
            clearTitleBeforeCommit()
            guard let navigation else { return }
            machine.apply(.failed(navigation, Self.loadError(code: code, text: text, url: url)))
        case .address(_, let url):
            machine.apply(.urlChanged(URL(string: url)))
        case .title(_, let title):
            machine.apply(.titleChanged(title.isEmpty ? nil : title))
            if capturesTitleBeforeCommit, state.phase == .provisional { titleBeforeCommit = title.isEmpty ? nil : title }
        case .favicon(_, let url):
            let faviconURL = URL(string: url)
            machine.apply(.faviconChanged(faviconURL))
            loadFavicon(faviconURL)
        case .progress(_, let value):
            machine.apply(.progress(value))
        case .fullscreen(_, let entering):
            machine.apply(.contentFullscreenChanged(entering))
        case .findResult(_, let count, let active, let isFinal):
            guard isFinal, let continuation = findContinuation else { return }
            findContinuation = nil
            continuation.resume(returning: BrowserFindResult(
                matchFound: count > 0, matchCount: count, currentIndex: count > 0 ? active : nil
            ))
        case .closeRequested:
            emit(.close)
        case .navigationReroute(_, let url, _):
            if let url = URL(string: url) { emit(.rerouteStore(url)) }
        case .keyUnhandled(_, let keyCode):
            if keyCode == 0x1B { emit(.unhandledEscape) }
        case .takeFocus(_, let forward):
            emit(.takeFocus(forward: forward))
        case .renderTerminated(_, let status, let code, _):
            rendererTerminated(.cef(status: status, code: code))
        case .renderUnresponsive:
            machine.apply(.unresponsiveChanged(true))
        case .renderResponsive:
            machine.apply(.unresponsiveChanged(false))
        default:
            break
        }
    }

    /// Chromium net error codes; -3 (ERR_ABORTED) is a cancelled load.
    static func loadError(code: Int, text: String, url: String) -> BrowserLoadError {
        if code == -3 {
            return BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: text, failingURL: URL(string: url))
        }
        return BrowserLoadError(domain: "net", code: code, message: text.isEmpty ? "net::\(code)" : text, failingURL: URL(string: url))
    }

    private func loadFavicon(_ url: URL?) {
        faviconTask?.cancel()
        guard let url else {
            favicon = nil
            return
        }
        let profile = profileID
        faviconTask = Task { [weak self] in
            let image = await BrowserFaviconLoader.shared.favicon(at: url, profile: profile)
            guard !Task.isCancelled else { return }
            self?.favicon = image
        }
    }

    // MARK: Scripts

    public func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        var params: [String: Any] = ["expression": script, "returnByValue": true, "awaitPromise": true]
        if world == .isolated {
            let tree = try await runtime.devTools(browserID, method: "Page.getFrameTree")
            guard let frame = CEFDevToolsResult.mainFrameID(tree) else { throw BrowserTabError.javaScript("no main frame") }
            let world = try await runtime.devTools(
                browserID, method: "Page.createIsolatedWorld", params: ["frameId": frame, "worldName": "cmux"]
            )
            guard let context = CEFDevToolsResult.executionContextID(world) else {
                throw BrowserTabError.javaScript("no isolated world")
            }
            params["contextId"] = context
        }
        let json = try await runtime.devTools(browserID, method: "Runtime.evaluate", params: params)
        return try CEFDevToolsResult.evaluation(json)
    }

    /// Runs a DevTools protocol method on this tab in process (diagnostics
    /// and trusted-input tests). Returns the method's JSON result.
    public func devTools(method: String, params: [String: any Sendable]) async throws -> String {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        return try await runtime.devTools(browserID, method: method, params: params)
    }

    // MARK: Find

    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        guard let browserID, !text.isEmpty, let shim = runtime.shim else { return .none }
        findContinuation?.resume(returning: .none)
        let findID = nextFindID
        nextFindID += 1
        return await withCheckedContinuation { continuation in
            findContinuation = continuation
            shim.find(browserID, findID, text, direction == .forward ? 1 : 0, caseSensitive ? 1 : 0, 1)
        }
    }

    public func clearFind() {
        findContinuation?.resume(returning: .none)
        findContinuation = nil
        browserID.map { runtime.shim?.stopFinding($0, 1) }
    }

    // MARK: Extension actions

    func refreshExtensionActions() {
        guard let browserID, let shim = runtime.shim, runtime.forkAPIVersion >= 1 else { return }
        let json = shim.takeString(shim.extActions(browserID, CEFExtensionAction.iconPixels)) ?? "[]"
        let actions = CEFExtensionAction.decodeList(json)
        if actions != extensionActions { extensionActions = actions }
    }

    public var extensionStore: BrowserExtensionStore { runtime.extensionStores.store(for: profileID) }

    public func runExtensionAction(_ id: String, anchor: CGRect) {
        guard let browserID else {
            // The click came before the page's browser exists (right after
            // launch): run it from `attach(browser:)`.
            pendingExtensionAction = (id, anchor)
            return
        }
        guard let shim = runtime.shim else { return }
        // The fork anchors the popup at the top edge of the browser area
        // between x and x + width (DIPs, browser view coordinates), so it
        // hangs below the toolbar button.
        let ran = shim.extActionRun(browserID, id, anchor.minX.clampedInt32, max(anchor.width, 1).clampedInt32) == 1
        if ran, extensionActions.first(where: { $0.id == id })?.hasPopup == true { openExtensionPopup = id }
    }

    public func hideExtensionPopups() {
        guard let browserID, let shim = runtime.shim, let open = openExtensionPopup else { return }
        shim.extActionHidePopup(browserID, open)
        openExtensionPopup = nil
    }

    /// The fork reported that this window's action popup closed.
    func extensionPopupClosed() {
        openExtensionPopup = nil
        refreshExtensionActions()
    }

    public func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint) {
        guard let browserID else { return }
        // Chromium screen DIPs have a top-left origin on the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        runtime.shim?.extActionContextMenu(browserID, id, point.x.clampedInt32, (primaryHeight - point.y).clampedInt32)
    }

    func clearTitleBeforeCommit() {
        titleBeforeCommit = nil
        capturesTitleBeforeCommit = false
    }
}
