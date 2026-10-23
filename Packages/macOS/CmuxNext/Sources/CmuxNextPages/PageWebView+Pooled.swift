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
    /// The Low Power Mode the spare renders by and follows (the pool's).
    let lowPowerMode: LowPowerMode
    let owner: PagePooledOwner
}

final class PagePooledOwner {
    weak var view: PageWebView?
}

extension PageWebView {
    static func hostConfiguration(handler: PageSchemeHandler, documentAttributes: [String: String],
                                  options: PageEngineOptions,
                                  lowPowerMode: LowPowerMode) -> (configuration: WKWebViewConfiguration,
                                                                  inputReadiness: PageInputReadiness) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = PageProcessPool.forNewView
        // The page's rate (PageRenderRate); WebKit's own default is the rate nearest 60 fps. The
        // view follows later Low Power Mode changes (followLowPowerMode).
        WebKitRenderRate.apply(fullRate: rendersAtFullRate(options.renderRate, lowPowerMode: lowPowerMode.isEnabled),
                               to: configuration.preferences)
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        let inputReadiness = PageInputReadiness(configuration: configuration)
        installPageScripts(configuration.userContentController, documentAttributes: documentAttributes)
        return (configuration, inputReadiness)
    }

    /// The configuration of a pooled host for `served`. `servedRoot` is where the spare's pages
    /// are served from (the bundled roots by default; tests pass a temporary one instead of
    /// registering a process-wide root). Nil when `served` is not a pooled page or has no root.
    static func pooledHostRecipe(_ served: PageDescriptor = .settings,
                                 options: PageEngineOptions = .standard,
                                 lowPowerMode: LowPowerMode,
                                 servedRoot: @escaping (PageDescriptor) -> URL? = { PageWebView.servedRoot(for: $0) }) -> PooledHostRecipe? {
        guard PageServedHosts.pooledDescriptors.contains(served), servedRoot(served) != nil else { return nil }
        let owner = PagePooledOwner()
        let handler = PageSchemeHandler { [weak owner] host in
            guard let view = owner?.view else { return nil }
            return PageServedHosts.served(host: host, current: view.descriptor, dynamicSource: view.dynamicResources,
                                          root: servedRoot)
        }
        let host = hostConfiguration(handler: handler, documentAttributes: [:], options: options,
                                     lowPowerMode: lowPowerMode)
        // The spare's document is parked until a claim binds routes (PageWebView+Claim.swift).
        host.configuration.userContentController.addUserScript(
            WKUserScript(source: parkedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        return PooledHostRecipe(served: served, configuration: host.configuration,
                                inputReadiness: host.inputReadiness, options: options,
                                lowPowerMode: lowPowerMode, owner: owner)
    }

    /// True while the view is the pool's parked spare (hidden, not claimed by any page).
    public var isParkedSpare: Bool { superview is PageHostParking }

    /// Makes a pooled page host without loading its document.
    convenience init(recipe: PooledHostRecipe, routes: [PageRoute] = []) {
        self.init(descriptor: recipe.served, configuration: recipe.configuration,
                  inputReadiness: recipe.inputReadiness, routes: routes, route: nil,
                  options: recipe.options, surface: nil, dynamicResources: nil, pooled: true, load: false,
                  lowPowerMode: recipe.lowPowerMode)
        pooledOwner = recipe.owner
        recipe.owner.view = self
    }

    /// Starts the served bundle document after the pooled view has been parked.
    func startLoading() {
        guard !loaded, webView.url == nil else { return }
        webView.load(URLRequest(url: descriptor.url()))
    }

    private static func installPageScripts(_ controller: WKUserContentController,
                                           documentAttributes: [String: String]) {
        controller.addUserScript(WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
        var attributes = documentAttributes
        if attributes["scrollers"] == nil { attributes["scrollers"] = SystemScrollers.pageValue }
        if let script = attributesScript(attributes) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true, in: .page))
        }
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
