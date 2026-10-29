public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import WebKit

/// What the scheme handler of a page made parked (``PageOpenRequest/parked``) reads its dynamic
/// resources through: the view, which gets them only with its claim (``PageWebView/bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``).
final class PagePooledOwner {
    weak var view: PageWebView?
}

extension PageWebView {
    /// `dataStore` is the store of the page's process group (``WebProcessGroups/dataStore(for:)``); nil
    /// gives the page a store of its own.
    static func hostConfiguration(handler: PageSchemeHandler, documentAttributes: [String: String],
                                  options: PageEngineOptions, dataStore: WKWebsiteDataStore? = nil)
        -> (configuration: WKWebViewConfiguration, inputReadiness: PageInputReadiness) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .nonPersistent()
        configuration.processPool = PageProcessPool.forNewView
        if options.fullFrameRate { WebKitRenderRate.apply(fullRate: true, to: configuration.preferences) }
        configuration.setURLSchemeHandler(handler, forURLScheme: PageDescriptor.scheme)
        let inputReadiness = PageInputReadiness(configuration: configuration)
        installPageScripts(configuration.userContentController, documentAttributes: documentAttributes)
        return (configuration, inputReadiness)
    }

    /// The scheme handler of a page made parked: it serves `page` from `root` as any page's handler
    /// does, and asks the view for the dynamic resources, which its claim binds after the document
    /// started loading.
    static func parkedSchemeHandler(page: PageDescriptor, root: URL, owner: PagePooledOwner) -> PageSchemeHandler {
        let host = page.id.lowercased()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        return PageSchemeHandler { [weak owner] requested in
            guard requested == host else { return nil }
            return PageSchemeHandler.Served(page: page, root: root, dynamicSource: owner?.view?.dynamicResources)
        }
    }

    /// The document-start script of a page made parked (``PageOpenRequest/parked``): its page client
    /// holds every call and subscription until the claim (PageWebView+Claim.swift).
    static func installParkedScript(_ controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: parkedScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .page))
    }

    /// True while the view waits in the preload slot's parking (``PagePreloadParkingView``): hidden
    /// to the person, not claimed by any open.
    public var isParkedSpare: Bool { superview is PagePreloadParkingView }

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
    }
}
