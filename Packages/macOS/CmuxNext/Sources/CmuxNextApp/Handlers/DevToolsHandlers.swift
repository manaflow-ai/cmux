import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemonService
import WebKit

/// The palette's Developer Tools set (`devtools.*`, plans/cmux-next/web-devtools.md)
/// on the focused web view (`WebInspectorTargets`). One binding per
/// `WebDevToolsCommand`; a command the target's engine cannot run is disabled
/// with the `WebDevToolsLimit` as its reason, never hidden.
enum DevToolsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for command in WebDevToolsCommand.allCases {
            let id = ActionID(rawValue: command.actionID)
            registry.bind(id, unavailable: { reason(command, context) }, run: { invocation in
                try run(command, on: target(invocation, context), invocation, context)
            })
            if command.isToggle || command.throttle != nil {
                ActionTargetTitles.setPaletteState(id, in: registry) { isOn(command, context) }
            }
        }
    }

    // MARK: Target

    /// The web view an inspector action acts on: the invocation's tab or
    /// pane, else the active window's focused web view.
    static func target(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> WebInspectorTarget {
        if invocation.target != nil {
            if let entry = try? context.page(invocation) { return .browser(entry.tab) }
            if let pane = context.scope(invocation).pane, let webView = WebInspectorTargets.webView(in: pane.view) {
                return .webView(webView)
            }
        }
        guard let target = WebInspectorTargets().target(in: context.services.windows.active) else {
            throw ActionFailure(message: WebDevToolsLimit.noWebView.message)
        }
        return target
    }

    /// Why the inspector actions are disabled now: no focused web view.
    static func noTargetReason(_ context: AppActionContext) -> String? {
        WebInspectorTargets().target(in: context.services.windows.active) == nil ? WebDevToolsLimit.noWebView.message : nil
    }

    private static func reason(_ command: WebDevToolsCommand, _ context: AppActionContext) -> String? {
        guard let target = WebInspectorTargets().target(in: context.services.windows.active) else {
            return WebDevToolsLimit.noWebView.message
        }
        return target.support(for: command).limit?.message
    }

    private static func isOn(_ command: WebDevToolsCommand, _ context: AppActionContext) -> Bool {
        guard case .browser(let tab)? = WebInspectorTargets().target(in: context.services.windows.active),
              let chromium = tab as? CEFTab else { return false }
        return chromium.devToolsModes.isOn(command)
    }

    // MARK: Running

    static func run(_ command: WebDevToolsCommand, on target: WebInspectorTarget, _ invocation: ActionInvocation,
                    _ context: AppActionContext) throws {
        if let limit = target.support(for: command).limit { throw ActionFailure(message: limit.message) }
        if case .browser(let tab) = target, let chromium = tab as? CEFTab {
            return runChromium(command, on: chromium, context)
        }
        guard let webView = target.webKitView else { throw ActionFailure(message: WebDevToolsLimit.chromiumOnly.message) }
        runWebKit(command, on: webView, tab: target, context)
    }

    private static func runChromium(_ command: WebDevToolsCommand, on tab: CEFTab, _ context: AppActionContext) {
        switch command {
        case .openDocked: open(tab, .bottom)
        case .openDockedRight: open(tab, .right)
        case .openInWindow: open(tab, .window)
        case .close: tab.performDevTools(.close)
        case .captureScreenshot: BrowserHandlers.copyScreenshot(context) { try await tab.snapshot() }
        case .captureFullPageScreenshot: BrowserHandlers.copyScreenshot(context) { try await tab.fullPageSnapshot() }
        case .viewPageSource:
            guard let url = tab.state.url, let source = URL(string: "view-source:\(url.absoluteString)") else { return }
            context.services.cache.pageRequests.browserTab(tab, didRequest: .openURL(source, .foregroundTab))
        default:
            if let panel = command.panel { return tab.performDevTools(.panel(panel)) }
            if let script = command.pageScript { return evaluate(script, in: tab) }
            var modes = tab.devToolsModes
            guard let calls = modes.calls(for: command, origin: origin(of: tab.state.url)) else { return }
            tab.devToolsModes = modes
            Task {
                for call in calls { _ = try? await tab.devTools(method: call.method, params: call.params) }
            }
        }
    }

    private static func open(_ tab: CEFTab, _ dock: BrowserDevToolsDock) {
        tab.performDevTools(.dock(dock))
        if !tab.devTools.isOpen { tab.performDevTools(.show) }
    }

    private static func runWebKit(_ command: WebDevToolsCommand, on webView: WKWebView, tab: WebInspectorTarget,
                                  _ context: AppActionContext) {
        let inspector = WebKitInspector(webView: webView)
        switch command {
        case .openDocked: inspector.attach()
        case .openInWindow: inspector.detach()
        case .close: inspector.close()
        case .togglePerformanceRecording: inspector.togglePageProfiling()
        case .viewPageSource: inspector.show(.sources)
        case .emptyCacheAndHardReload:
            removeSiteData(of: webView, types: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) { webView.reloadFromOrigin() }
        case .clearSiteData:
            removeSiteData(of: webView, types: WKWebsiteDataStore.allWebsiteDataTypes()) { webView.reloadFromOrigin() }
        case .captureScreenshot:
            BrowserHandlers.copyScreenshot(context) {
                if case .browser(let tab) = tab { return try await tab.snapshot() }
                let image = try await webView.takeSnapshot(configuration: nil)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw ActionFailure(message: WebDevToolsLimit.browserTabOnly.message)
                }
                return cgImage
            }
        case .captureFullPageScreenshot:
            if case .browser(let tab) = tab { BrowserHandlers.copyScreenshot(context) { try await tab.fullPageSnapshot() } }
        default:
            if let panel = command.panel { return inspector.show(panel) }
            if let script = command.pageScript {
                if case .browser(let page) = tab { return evaluate(script, in: page) }
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }

    // MARK: Helpers

    private static func evaluate(_ script: String, in tab: any BrowserTab) {
        Task { _ = try? await tab.evaluate(script, world: .page, gesture: .agent) }
    }

    /// The page's origin (`https://example.com:8443`) for Storage.clearDataForOrigin.
    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Removes `types` of the page's site (its host's records) from the web view's data store.
    private static func removeSiteData(of webView: WKWebView, types: Set<String>, then done: @escaping @MainActor () -> Void) {
        guard let host = webView.url?.host() else { return done() }
        let store = webView.configuration.websiteDataStore
        Task {
            let records = await store.dataRecords(ofTypes: types)
            let site = records.filter { host == $0.displayName || host.hasSuffix(".\($0.displayName)") }
            await store.removeData(ofTypes: types, for: site)
            done()
        }
    }
}
