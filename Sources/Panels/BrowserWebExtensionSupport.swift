import AppKit
import SwiftUI
import WebKit

/// Hosts Chrome/Safari-style web extensions in the built-in browser via WebKit's
/// native `WKWebExtensionController` API (macOS 15.4+).
///
/// One shared controller (persistent storage keyed by a fixed identifier) is attached
/// to every browser `WKWebViewConfiguration`. Extensions are discovered from:
/// - directories listed in the `CMUX_BROWSER_EXTENSIONS` environment variable
///   (colon-separated paths to unpacked extensions or `.appex` bundles), and
/// - the Bitwarden desktop app's bundled Safari web extension, when installed.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionSupport: NSObject, ObservableObject {
    static let shared = BrowserWebExtensionSupport()

    /// Fixed identifier so extension storage (e.g. the Bitwarden vault cache)
    /// persists across app launches.
    private static let controllerIdentifier = UUID(uuidString: "8C0FDE2B-6EFD-4E8C-9E70-8E7D0A4C51B7")!

    /// Bundled Safari web extension inside the Bitwarden desktop app.
    private static let bitwardenAppexURL = URL(
        fileURLWithPath: "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"
    )

    let controller: WKWebExtensionController

    @Published private(set) var contexts: [WKWebExtensionContext] = []
    @Published private(set) var loadErrors: [String] = []

    private var didStartLoading = false
    private var tabAdapters: [UUID: BrowserWebExtensionTabAdapter] = [:]
    private var orderedPanelIDs: [UUID] = []
    private(set) var activePanelID: UUID?
    private(set) lazy var windowAdapter = BrowserWebExtensionWindowAdapter(support: self)
    private var popouts: [BrowserWebExtensionPopoutWindowController] = []

    /// Anchor for the next action popup presentation, set by the toolbar button
    /// immediately before calling `performAction(context:panel:anchorView:)`.
    private weak var pendingPopupAnchorView: NSView?

    private var nativeMessageDropCount = 0

    private override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        // Extension-owned web views (background page, action popup) get WebKit's
        // default user agent, which lacks the " Safari/" token. Extensions like
        // Bitwarden classify the browser from the UA and crash on an unknown one,
        // so present the same Safari application identity the browser panels use.
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webViewConfiguration.applicationNameForUserAgent = "Version/26.2 Safari/605.1.15"
        configuration.webViewConfiguration = webViewConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: - Configuration attachment

    /// Attaches the shared extension controller to a browser web view configuration
    /// and kicks off extension discovery on first use.
    func attach(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
        loadInstalledExtensionsIfNeeded()
    }

    private func loadInstalledExtensionsIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        Task { await loadInstalledExtensions() }
    }

    private func loadInstalledExtensions() async {
        for url in Self.candidateExtensionURLs() {
            do {
                let webExtension: WKWebExtension
                if url.pathExtension == "appex" {
                    if let bundle = Bundle(url: url) {
                        webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                    } else {
                        // Fall back to reading the appex's web-extension resources directly.
                        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
                        webExtension = try await WKWebExtension(resourceBaseURL: resources)
                    }
                } else {
                    webExtension = try await WKWebExtension(resourceBaseURL: url)
                }
                try load(webExtension)
#if DEBUG
                cmuxDebugLog(
                    "browser.webext.loaded name=\(webExtension.displayName ?? "?") " +
                    "version=\(webExtension.displayVersion ?? "?") url=\(url.path)"
                )
#endif
            } catch {
                loadErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
#if DEBUG
                cmuxDebugLog("browser.webext.loadFailed url=\(url.path) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func load(_ webExtension: WKWebExtension) throws {
        let context = WKWebExtensionContext(for: webExtension)
        // Grant everything the manifest requests up front; interactive permission
        // prompting can come later. Repeat grants are also answered by the
        // prompt delegate methods below.
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
#if DEBUG
        context.isInspectable = true
#endif
        try controller.load(context)
        contexts.append(context)
#if DEBUG
        logDiagnostics(for: context, label: "postLoad")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.logDiagnostics(for: context, label: "postLoad+5s")
        }
        if ProcessInfo.processInfo.environment["CMUX_WEBEXT_AUTOPROBE"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                cmuxDebugLog("browser.webext.autoprobe performAction")
                context.performAction(for: self.activeTabAdapter)
            }
        }
#endif
    }

#if DEBUG
    private func logDiagnostics(for context: WKWebExtensionContext, label: String) {
        let ext = context.webExtension
        cmuxDebugLog(
            "browser.webext.diag(\(label)) name=\(ext.displayName ?? "?") " +
            "loaded=\(context.isLoaded ? 1 : 0) " +
            "injected=\(ext.hasInjectedContent ? 1 : 0) " +
            "background=\(ext.hasBackgroundContent ? 1 : 0) " +
            "allURLs=\(context.hasAccessToAllURLs ? 1 : 0) " +
            "perms=\(context.currentPermissions.count) " +
            "patterns=\(context.currentPermissionMatchPatterns.count) " +
            "openTabs=\(context.openTabs.count) " +
            "ctxErrors=\(context.errors.map(\.localizedDescription).joined(separator: " | ")) " +
            "extErrors=\(ext.errors.map(\.localizedDescription).joined(separator: " | "))"
        )
        for command in context.commands {
            cmuxDebugLog(
                "browser.webext.command registered id=\(command.id) " +
                "key=\(command.activationKey ?? "nil") mods=\(command.modifierFlags.rawValue) " +
                "title=\(command.title)"
            )
        }
    }
#endif

    /// Extension bundles/directories to try loading, in order.
    private static func candidateExtensionURLs() -> [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CMUX_BROWSER_EXTENSIONS"] {
            for path in env.split(separator: ":") where !path.isEmpty {
                urls.append(URL(fileURLWithPath: String(path)))
            }
        }
        if FileManager.default.fileExists(atPath: bitwardenAppexURL.path) {
            urls.append(bitwardenAppexURL)
        }
        return urls
    }

    // MARK: - Tab lifecycle (called from BrowserPanel)

    func register(panel: BrowserPanel) {
        guard tabAdapters[panel.id] == nil else { return }
        let adapter = BrowserWebExtensionTabAdapter(panel: panel, support: self)
        tabAdapters[panel.id] = adapter
        orderedPanelIDs.append(panel.id)
        if activePanelID == nil { activePanelID = panel.id }
        controller.didOpenTab(adapter)
    }

    func unregister(panelID: UUID) {
        guard let adapter = tabAdapters.removeValue(forKey: panelID) else { return }
        orderedPanelIDs.removeAll { $0 == panelID }
        if activePanelID == panelID { activePanelID = orderedPanelIDs.last }
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func noteActivated(panelID: UUID) {
        guard tabAdapters[panelID] != nil, activePanelID != panelID else { return }
        let previous = activePanelID.flatMap { tabAdapters[$0] }
        activePanelID = panelID
        if let adapter = tabAdapters[panelID] {
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
    }

    func tabAdapter(for panelID: UUID) -> BrowserWebExtensionTabAdapter? {
        tabAdapters[panelID]
    }

    var orderedTabAdapters: [BrowserWebExtensionTabAdapter] {
        orderedPanelIDs.compactMap { tabAdapters[$0] }
    }

    var activeTabAdapter: BrowserWebExtensionTabAdapter? {
        activePanelID.flatMap { tabAdapters[$0] }
    }

    func indexInWindow(of panelID: UUID) -> Int {
        orderedPanelIDs.firstIndex(of: panelID) ?? 0
    }

    // MARK: - Action popup

    /// Performs the extension's toolbar action for `panel`, anchoring any popup
    /// the extension presents to `anchorView`.
    func performAction(context: WKWebExtensionContext, panel: BrowserPanel, anchorView: NSView?) {
        noteActivated(panelID: panel.id)
        pendingPopupAnchorView = anchorView
        context.performAction(for: tabAdapter(for: panel.id))
    }

    // MARK: - Keyboard commands

    /// Offers a key equivalent to loaded extensions' declared commands
    /// (e.g. Bitwarden's ⌘⇧L autofill). Returns true when one handled it.
    func performCommand(for event: NSEvent) -> Bool {
        for context in contexts where context.performCommand(for: event) {
#if DEBUG
            cmuxDebugLog("browser.webext.command handled name=\(context.webExtension.displayName ?? "?")")
#endif
            return true
        }
#if DEBUG
        if !contexts.isEmpty {
            cmuxDebugLog(
                "browser.webext.command unmatched key=\(event.charactersIgnoringModifiers ?? "?") " +
                "mods=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
            )
        }
#endif
        return false
    }

    // MARK: - Popout windows

    func popoutDidClose(_ popout: BrowserWebExtensionPopoutWindowController) {
        guard popouts.contains(where: { $0 === popout }) else { return }
        popouts.removeAll { $0 === popout }
        controller.didCloseTab(popout.tab, windowIsClosing: true)
        controller.didCloseWindow(popout)
    }
}

// MARK: - WKWebExtensionControllerDelegate

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [windowAdapter] + popouts
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        popouts.first(where: \.isKeyWindow) ?? windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
#if DEBUG
        cmuxDebugLog(
            "browser.webext.openWindow type=\(configuration.windowType.rawValue) " +
            "urls=\(configuration.tabURLs.count) focused=\(configuration.shouldBeFocused ? 1 : 0)"
        )
#endif
        let popout = BrowserWebExtensionPopoutWindowController(
            configuration: configuration,
            context: extensionContext,
            support: self
        )
        popouts.append(popout)
        controller.didOpenWindow(popout)
        controller.didOpenTab(popout.tab)
        completionHandler(popout, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
#if DEBUG
        cmuxDebugLog("browser.webext.openTab url=\(configuration.url?.absoluteString.prefix(80) ?? "nil")")
#endif
        // External pages go to the user's default browser context inside cmux
        // panels eventually; for now open http(s) URLs via the system and host
        // extension pages in a popout window.
        if let url = configuration.url, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            completionHandler(nil, nil)
            return
        }
        completionHandler(nil, NSError(
            domain: "cmux.webExtension", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Opening extension tabs is not supported yet"]
        ))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        let candidates: [NSView?] = [
            pendingPopupAnchorView,
            activeTabAdapter?.panel?.webView,
            orderedTabAdapters.first(where: { $0.panel?.webView.window != nil })?.panel?.webView,
            NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView,
        ]
        pendingPopupAnchorView = nil
        guard let anchor = candidates.compactMap({ $0 }).first(where: { $0.window != nil }) else {
#if DEBUG
            cmuxDebugLog("browser.webext.actionPopup no window-attached anchor; dropping popup")
#endif
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_WEBEXT_AUTOPROBE"] == "1",
           let popupWebView = action.popupWebView {
            probePopup(popupWebView)
        }
#endif
        completionHandler(nil)
    }

#if DEBUG
    /// Evaluates a WebExtension-API probe inside the action popup so tab/window
    /// adapter behavior is observable from the extension's point of view.
    /// Installs an error-capture hook and reloads the popup first so boot-time
    /// console errors and unhandled rejections are observable.
    private func probePopup(_ popupWebView: WKWebView) {
        Task { @MainActor in
            let hookSource = """
            window.__errs = [];
            window.addEventListener("error", (e) => window.__errs.push("E:" + e.message + "@" + (e.filename || "") + ":" + (e.lineno || 0)));
            window.addEventListener("unhandledrejection", (e) => window.__errs.push("R:" + ((e.reason && (e.reason.stack || e.reason.message)) || e.reason)));
            const ce = console.error.bind(console);
            console.error = (...a) => { window.__errs.push("C:" + a.map(String).join(" ").slice(0, 300)); ce(...a); };
            """
            popupWebView.configuration.userContentController.addUserScript(
                WKUserScript(source: hookSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
            popupWebView.reload()
            try? await Task.sleep(for: .seconds(5))
            let script = """
            try {
              const api = globalThis.browser || globalThis.chrome;
              const tabs = await api.tabs.query({ active: true, currentWindow: true });
              const wins = await api.windows.getAll();
              const win = await api.windows.getCurrent().catch((e) => 'ERR:' + e.message);
              let popoutTest = "skipped";
              try {
                const w = await api.windows.create({ url: "popup/index.html", type: "popup", width: 380, height: 500, focused: false });
                popoutTest = w ? "created:" + w.id + ":tabs=" + (w.tabs ? w.tabs.length : "?") : "null";
                if (w) { await new Promise(r => setTimeout(r, 1500)); await api.windows.remove(w.id); popoutTest += ":removed"; }
              } catch (e) { popoutTest = "ERR:" + (e && e.message); }
              return JSON.stringify({
                ready: document.readyState,
                bodyChildren: document.body ? document.body.children.length : -1,
                tabCount: tabs.length,
                tab0: tabs[0] ? `${tabs[0].id}:${tabs[0].url || "nourl"}:${tabs[0].title || "notitle"}` : "none",
                winCount: wins.length,
                currentWin: typeof win === "string" ? win : (win ? win.id : "none"),
                text: (document.body ? document.body.innerText : "").replace(/\\s+/g, " ").slice(0, 160),
                html: (document.body ? document.body.innerHTML : "").replace(/\\s+/g, " ").slice(0, 240),
                errs: (window.__errs || []).slice(0, 8),
                popoutTest
              });
            } catch (e) { return "ERR:" + (e && e.message); }
            """
            popupWebView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    cmuxDebugLog("browser.webext.popupProbe \(value ?? "nil")")
                case .failure(let error):
                    cmuxDebugLog("browser.webext.popupProbe error=\(error.localizedDescription)")
                }
            }
        }
    }
#endif

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        // Native messaging (e.g. Bitwarden's desktop-app biometrics IPC) is not
        // bridged. Never resolve the reply: an error reply sends Bitwarden into
        // an unthrottled reconnect loop (observed ~175k messages/sec), while an
        // unresolved promise parks the caller harmlessly.
        nativeMessageDropCount += 1
        if nativeMessageDropCount <= 5 {
#if DEBUG
            cmuxDebugLog(
                "browser.webext.nativeMessage dropped app=\(applicationIdentifier ?? "nil") " +
                "count=\(nativeMessageDropCount)"
            )
#endif
        }
        _ = replyHandler
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // See sendMessage above: leave the native port unresolved rather than
        // erroring, so extensions do not retry-loop.
#if DEBUG
        cmuxDebugLog("browser.webext.nativeConnect dropped app=\(port.applicationIdentifier ?? "nil")")
#endif
        _ = completionHandler
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}
