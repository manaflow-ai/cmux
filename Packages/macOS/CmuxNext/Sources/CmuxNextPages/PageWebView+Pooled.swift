import CmuxNextErrorJournal
public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import WebKit

/// The configuration and input readiness object made before a pooled WebKit view exists.
struct PooledHostRecipe {
    let served: PageDescriptor
    let configuration: WKWebViewConfiguration
    let inputReadiness: PageInputReadiness
    let options: PageEngineOptions
    let owner: PagePooledOwner
    /// The groups the configuration's pool and store come from; the view relates in them.
    let processGroups: PageProcessGroups
}

final class PagePooledOwner {
    weak var view: PageWebView?
}

extension PageWebView {
    /// A page's WebKit configuration: `group`'s store and pool in `processGroups`, scheme and scripts.
    static func hostConfiguration(handler: PageSchemeHandler, documentAttributes: [String: String],
                                  options: PageEngineOptions, group: PageProcessGroup,
                                  in processGroups: PageProcessGroups) -> (configuration: WKWebViewConfiguration,
                                                                           inputReadiness: PageInputReadiness) {
        let configuration = WKWebViewConfiguration()
        processGroups.configure(configuration, for: group)
        if options.fullFrameRate { WebKitRenderRate.apply(fullRate: true, to: configuration.preferences) }
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        let inputReadiness = PageInputReadiness(configuration: configuration)
        installPageScripts(configuration.userContentController, documentAttributes: documentAttributes)
        return (configuration, inputReadiness)
    }

    static func pooledHostRecipe(_ served: PageDescriptor = .settings, options: PageEngineOptions = .standard,
                                 processGroups: PageProcessGroups) -> PooledHostRecipe? {
        guard PageServedHosts.pooledDescriptors.contains(served), servedRoot(for: served) != nil else { return nil }
        let owner = PagePooledOwner()
        let handler = PageSchemeHandler { [weak owner] host in
            guard let view = owner?.view else { return nil }
            return PageServedHosts.served(host: host, current: view.descriptor, dynamicSource: view.dynamicResources)
        }
        let host = hostConfiguration(handler: handler, documentAttributes: [:], options: options,
                                     group: served.processGroup, in: processGroups)
        // The spare's document is parked until a claim binds routes (PageWebView+Claim.swift).
        host.configuration.userContentController.addUserScript(
            WKUserScript(source: parkedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        return PooledHostRecipe(served: served, configuration: host.configuration,
                                inputReadiness: host.inputReadiness, options: options, owner: owner,
                                processGroups: processGroups)
    }

    /// True while the view is the pool's parked spare (hidden, not claimed by any page).
    public var isParkedSpare: Bool { superview is PageHostParking }

    /// Makes a pooled page host without loading its document.
    convenience init(recipe: PooledHostRecipe, routes: [PageRoute] = []) {
        self.init(descriptor: recipe.served, configuration: recipe.configuration,
                  inputReadiness: recipe.inputReadiness, routes: routes, route: nil,
                  options: recipe.options, surface: nil, dynamicResources: nil, pooled: true, load: false,
                  processGroups: recipe.processGroups)
        pooledOwner = recipe.owner
        recipe.owner.view = self
    }

    /// Starts the served bundle document after the pooled view has been parked.
    func startLoading() {
        guard !loaded, webView.url == nil else { return }
        traceOpenRequested(.spare)
        webView.load(URLRequest(url: descriptor.url()))
    }

    private static func installPageScripts(_ controller: WKUserContentController,
                                           documentAttributes: [String: String]) {
        controller.addUserScript(WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
        var attributes = documentAttributes
        if attributes["scrollers"] == nil { attributes["scrollers"] = SystemScrollers.pageValue }
        // `data-engine="webkit"`: only this engine serves a framed document its own sandboxed policy
        // (``PageResource/sandboxedPolicy``), so a page frames one only here (the agent page's render cards).
        attributes["engine"] = "webkit"
        if let script = attributesScript(attributes) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true, in: .page))
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        // The refactor oracle's page state (p15-oracle-215): pages serve it only in DEV and bench builds.
        controller.addUserScript(WKUserScript(source: oracleStateScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
        #endif
    }

    /// Reinstalls document-start scripts after a pooled host changes its page origin.
    func reinstallPageScripts(documentAttributes: [String: String]) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: PageInputReadiness.script, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
        Self.installPageScripts(controller, documentAttributes: documentAttributes)
        controller.addUserScript(WKUserScript(source: PagePaintProbe.script, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: .page))
        // The handler stays installed; only the script was removed with the others.
        controller.addUserScript(WKUserScript(source: ConsoleErrorCapture.script, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
    }
}
