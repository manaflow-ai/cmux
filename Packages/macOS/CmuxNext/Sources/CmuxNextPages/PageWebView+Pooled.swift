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
}

final class PagePooledOwner {
    weak var view: PageWebView?
}

extension PageWebView {
    static func hostConfiguration(handler: PageSchemeHandler, documentAttributes: [String: String],
                                  options: PageEngineOptions) -> (configuration: WKWebViewConfiguration,
                                                                   inputReadiness: PageInputReadiness) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = PageProcessPool.forNewView
        if options.fullFrameRate { WebKitRenderRate.apply(fullRate: true, to: configuration.preferences) }
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        let inputReadiness = PageInputReadiness(configuration: configuration)
        installPageScripts(configuration.userContentController, documentAttributes: documentAttributes)
        return (configuration, inputReadiness)
    }

    static func pooledHostRecipe(_ served: PageDescriptor = .settings,
                                 options: PageEngineOptions = .standard) -> PooledHostRecipe? {
        guard PageServedHosts.pooledDescriptors.contains(served), servedRoot(for: served) != nil else { return nil }
        let owner = PagePooledOwner()
        let handler = PageSchemeHandler { [weak owner] host in
            guard let view = owner?.view else { return nil }
            return PageServedHosts.served(host: host, current: view.descriptor, dynamicSource: view.dynamicResources)
        }
        let host = hostConfiguration(handler: handler, documentAttributes: [:], options: options)
        return PooledHostRecipe(served: served, configuration: host.configuration,
                                inputReadiness: host.inputReadiness, options: options, owner: owner)
    }

    /// Makes a pooled page host without loading its document.
    convenience init(recipe: PooledHostRecipe, routes: [PageRoute] = []) {
        self.init(descriptor: recipe.served, configuration: recipe.configuration,
                  inputReadiness: recipe.inputReadiness, routes: routes, route: nil,
                  options: recipe.options, surface: nil, dynamicResources: nil, pooled: true, load: false)
        pooledOwner = recipe.owner
        recipe.owner.view = self
    }

    /// Makes and starts a pooled page host in one call.
    convenience init?(pooledHost served: PageDescriptor = .settings, routes: [PageRoute] = [],
                      options: PageEngineOptions = .standard) {
        guard let recipe = Self.pooledHostRecipe(served, options: options) else { return nil }
        self.init(recipe: recipe, routes: routes)
        startLoading()
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
    }
}
