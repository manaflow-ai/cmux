public import AppKit
public import CmuxNextSettings
public import WebKit

/// The configuration step of a pooled host, built in its own main-actor turn (``PageHostPool``
/// splits a spare build into configure, create, park and load so no step holds a frame).
public struct PooledHostRecipe {
    let served: PageDescriptor
    let configuration: WKWebViewConfiguration
    let owner: PageServedOwner
}

/// Pooled hosts (``PageHostPool``): one scheme handler for every first-party page
/// (``PageServedHosts``) and their own non-persistent website data store, so no host sees
/// another host's storage.
extension PageWebView {
    /// Step 1: the configuration of a pooled host that shows `served`. Nil when `served` is not a
    /// first-party page with a root.
    public static func pooledHostRecipe(_ served: PageDescriptor = .shell,
                                        options: PageEngineOptions = .standard) -> PooledHostRecipe? {
        guard PageID.isFirstParty(served.id), servedRoot(for: served) != nil else { return nil }
        let owner = PageServedOwner()
        let handler = PageSchemeHandler { host in owner.view?.servedHost(host) }
        return PooledHostRecipe(served: served,
                                configuration: configuration(handler: handler, documentAttributes: [:], options: options),
                                owner: owner)
    }

    /// Step 2: the host view, not loading yet (``startLoading()`` is step 3).
    public convenience init(recipe: PooledHostRecipe, routes: [PageRoute] = []) {
        self.init(descriptor: recipe.served, configuration: recipe.configuration, routes: routes, route: nil,
                  surface: nil, dynamicResources: nil, pooled: true, load: false)
        recipe.owner.view = self
    }

    /// A pooled host that shows `served` (default the page shell), built and loading in one call.
    public convenience init?(pooledHost served: PageDescriptor = .shell, routes: [PageRoute] = [],
                             options: PageEngineOptions = .standard) {
        guard let recipe = Self.pooledHostRecipe(served, options: options) else { return nil }
        self.init(recipe: recipe, routes: routes)
        startLoading()
    }

    /// Hands the claim's session to the shell page mounted ahead of its claim (`page.resume
    /// {page, route, context}`): no mount, the page shows the session in its next render. Routes
    /// for later calls become `routes`; the streams the page opened while prepared stay open.
    public func sendResume(routes: [PageRoute], route: String?, context: JSONValue,
                           reply: ((Result<JSONValue, PageError>) -> Void)? = nil) {
        router.replaceRoutes(routes)
        paintedUptime = nil
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        let params: JSONValue = ["page": .string(descriptor.id), "route": .string(self.route ?? ""), "context": context]
        router.sendCall(PageShellOp.resume, params: params) { reply?($0) }
    }
}
