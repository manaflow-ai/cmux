/// The providers' freeze hooks: the providers of a frozen page stop the sources behind
/// their streams. Their freeze state follows the engine's (``PageWebView/freezePage()``), not the
/// document's: a frozen page whose document reloads or commits stays frozen, so its new streams start
/// paused, and only the engine's thaw (or the page's close) thaws them.
extension PageRouter {
    /// Tells each provider of the page's routes once that the page froze (``PageProvider/pageWillFreeze()``):
    /// they stop the sources behind their streams. A second call before ``pageDidThaw()`` does nothing.
    /// As Chrome's `WebUIImpl` calls `OnJavascriptDisallowed` on every handler of the page
    /// (content/browser/webui/web_ui_impl.cc, `DisallowJavascriptOnAllHandlers`).
    public func pageWillFreeze() {
        guard !providersFrozen else { return }
        providersFrozen = true
        for provider in routeProviders { provider.pageWillFreeze() }
    }

    /// Tells each provider once that the page thawed (``PageProvider/pageDidThaw()``), in the thaw's
    /// turn: their resyncs reach the hold, or the page, before anything the hold kept is released.
    /// ``close()`` of a frozen page calls it after cancelling every stream, and ``PageWebView`` calls
    /// it wherever its engine stops being frozen, so a provider's freeze state is the engine's.
    public func pageDidThaw() {
        guard providersFrozen else { return }
        providersFrozen = false
        for provider in routeProviders { provider.pageDidThaw() }
    }

    /// Each provider of the routes once (a relay serves several namespaces), in route order.
    private var routeProviders: [any PageProvider] {
        var seen = Set<ObjectIdentifier>()
        return routes.map { $0.provider }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}
